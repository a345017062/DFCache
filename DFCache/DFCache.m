// The MIT License (MIT)
//
// Copyright (c) 2014 Alexander Grebenyuk (github.com/kean).
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "DFCache.h"
#import "DFCachePrivate.h"
#import "DFCacheTimer.h"
#import "DFValueTransformer.h"
#import "DFValueTransformerFactory.h"
#import "NSURL+DFExtendedFileAttributes.h"


NSString *const DFCacheAttributeMetadataKey = @"_df_cache_metadata_key";
NSString *const DFCacheAttributeValueTransformerKey = @"_df_cache_value_transformer_key";


@implementation DFCache {
    BOOL _cleanupTimerEnabled;
    NSTimeInterval _cleanupTimeInterval;
    NSTimer *__weak _cleanupTimer;
    
    /*! Serial dispatch queue used for all disk IO operations. If you store the object using DFCache asynchronous API and then immediately try to retrieve it then you are guaranteed to get the object back.
     */
    dispatch_queue_t _ioQueue;
    
    /*! Concurrent dispatch queue used for dispatching blocks that decode cached data.
     */
    dispatch_queue_t _processingQueue;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_cleanupTimer invalidate];
}

- (instancetype)initWithDiskCache:(DFDiskCache *)diskCache memoryCache:(NSCache *)memoryCache {
    if (self = [super init]) {
        if (!diskCache) {
            [NSException raise:NSInvalidArgumentException format:@"Attempting to initialize DFCache without disk cache"];
        }
        _diskCache = diskCache;
        _memoryCache = memoryCache;
        
        _valueTransfomerFactory = [DFValueTransformerFactory defaultFactory];
        
        _ioQueue = dispatch_queue_create("DFCache::IOQueue", DISPATCH_QUEUE_SERIAL);
        _processingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        _cleanupTimeInterval = 60.f;
        _cleanupTimerEnabled = YES;
        [self _scheduleCleanupTimer];
        
#if (__IPHONE_OS_VERSION_MIN_REQUIRED)
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name memoryCache:(NSCache *)memoryCache {
    if (!name.length) {
        [NSException raise:NSInvalidArgumentException format:@"Attemting to initialize DFCache without a name"];
    }
    DFDiskCache *diskCache = [[DFDiskCache alloc] initWithName:name];
    diskCache.capacity = 1024 * 1024 * 100; // 100 Mb
    diskCache.cleanupRate = 0.5f;
    return [self initWithDiskCache:diskCache memoryCache:memoryCache];
}

- (instancetype)initWithName:(NSString *)name {
    NSCache *memoryCache = [NSCache new];
    memoryCache.name = name;
    return [self initWithName:name memoryCache:memoryCache];
}

#pragma mark - Read (Asynchronous)

- (void)cachedObjectForKey:(NSString *)key completion:(void (^)(id))completion {
    [self cachedObjectForKey:key valueTransformer:nil completion:completion];
}

- (void)cachedObjectForKey:(NSString *)key valueTransformer:(id<DFValueTransforming>)valueTransformer completion:(void (^)(id))completion {
    if (!key.length) {
        _dwarf_cache_callback(completion, nil);
        return;
    }
    id object = [self.memoryCache objectForKey:key];
    if (object) {
        _dwarf_cache_callback(completion, object);
        return;
    }
    [self _cachedObjectForKey:key valueTransformer:valueTransformer completion:completion];
}

- (void)_cachedObjectForKey:(NSString *)key valueTransformer:(id<DFValueTransforming>)inputValueTransformer completion:(void (^)(id))completion {
    dispatch_async(_ioQueue, ^{
        NSData *data = [self.diskCache dataForKey:key];
        if (!data) {
            _dwarf_cache_callback(completion, nil);
            return;
        }
        id<DFValueTransforming> valueTransformer = inputValueTransformer;
        if (!inputValueTransformer) {
            NSURL *fileURL = [self.diskCache URLForKey:key];
            valueTransformer = [fileURL df_extendedAttributeValueForKey:DFCacheAttributeValueTransformerKey error:nil];
        }
        NSParameterAssert(valueTransformer);
        dispatch_async(_processingQueue, ^{
            @autoreleasepool {
                id object = [valueTransformer reverseTransfomedValue:data];
                [self _setObject:object forKey:key valueTransformer:valueTransformer];
                _dwarf_cache_callback(completion, object);
            }
        });
    });
}

#pragma mark - Read (Synchronous)

- (id)cachedObjectForKey:(NSString *)key {
    return [self cachedObjectForKey:key valueTransformer:nil];
}

- (id)cachedObjectForKey:(NSString *)key valueTransformer:(id<DFValueTransforming>)valueTransformer {
    if (!key.length) {
        return nil;
    }
    id object = [self.memoryCache objectForKey:key];
    if (object) {
        return object;
    }
    @autoreleasepool {
        return [self _cachedObjectForKey:key valueTransformer:valueTransformer];
    }
}

- (id)_cachedObjectForKey:(NSString *)key valueTransformer:(id<DFValueTransforming>)inputValueTransformer {
    NSData *__block data;
    id<DFValueTransforming> __block valueTransformer = inputValueTransformer;
    dispatch_sync(_ioQueue, ^{
        data = [self.diskCache dataForKey:key];
        if (!valueTransformer) {
            NSURL *fileURL = [self.diskCache URLForKey:key];
            valueTransformer = [fileURL df_extendedAttributeValueForKey:DFCacheAttributeValueTransformerKey error:nil];
        }
    });
    id object = [valueTransformer reverseTransfomedValue:data];
    [self _setObject:object forKey:key valueTransformer:valueTransformer];
    return object;
}

#pragma mark - Write

- (void)storeObject:(id)object forKey:(NSString *)key {
    [self storeObject:object valueTransformer:nil data:nil forKey:key];
}

- (void)storeObject:(id)object data:(NSData *)data forKey:(NSString *)key {
    [self storeObject:object valueTransformer:nil data:data forKey:key];
}

- (void)storeObject:(id)object valueTransformer:(id<DFValueTransforming>)valueTransformer forKey:(NSString *)key {
    [self storeObject:object valueTransformer:valueTransformer data:nil forKey:key];
}

- (void)storeObject:(id)object valueTransformer:(id<DFValueTransforming>)valueTransformer data:(NSData *)data forKey:(NSString *)key {
    if (!key.length) {
        return;
    }
    if (!valueTransformer) {
        valueTransformer = [self.valueTransfomerFactory valueTransformerForValue:object];
    }
    [self _setObject:object forKey:key valueTransformer:valueTransformer];
    if (!data && !valueTransformer) {
        return;
    }
    dispatch_async(_ioQueue, ^{
        @autoreleasepool {
            NSData *__block encodedData = data;
            if (!encodedData) {
                @try {
                    encodedData = [valueTransformer transformedValue:object];
                }
                @catch (NSException *exception) {
                    // Do nothing
                }
            }
            if (encodedData) {
                [self.diskCache setData:encodedData forKey:key];
                if (valueTransformer) {
                    NSURL *fileURL = [self.diskCache URLForKey:key];
                    [fileURL df_setExtendedAttributeValue:valueTransformer forKey:DFCacheAttributeValueTransformerKey];
                }
            }
        }
    });
}

- (void)_setObject:(id)object forKey:(NSString *)key valueTransformer:(id<DFValueTransforming>)valueTransformer {
    if (!object || !key.length) {
        return;
    }
    NSUInteger cost = 0;
    if ([valueTransformer respondsToSelector:@selector(costForValue:)]) {
        cost = [valueTransformer costForValue:object];
    }
    [self.memoryCache setObject:object forKey:key cost:cost];
}

#pragma mark - Remove

- (void)removeObjectsForKeys:(NSArray *)keys {
    if (!keys.count) {
        return;
    }
    for (NSString *key in keys) {
        [self.memoryCache removeObjectForKey:key];
    }
    dispatch_async(_ioQueue, ^{
        for (NSString *key in keys) {
            [self.diskCache removeDataForKey:key];
        }
    });
}

- (void)removeObjectForKey:(NSString *)key {
    if (key) {
        [self removeObjectsForKeys:@[key]];
    }
}

- (void)removeAllObjects {
    [self.memoryCache removeAllObjects];
    dispatch_async(_ioQueue, ^{
        [self.diskCache removeAllData];
    });
}

#pragma mark - Metadata

- (NSDictionary *)metadataForKey:(NSString *)key {
    if (!key.length) {
        return nil;
    }
    NSDictionary *__block metadata;
    dispatch_sync(_ioQueue, ^{
        NSURL *fileURL = [self.diskCache URLForKey:key];
        metadata = [fileURL df_extendedAttributeValueForKey:DFCacheAttributeMetadataKey error:nil];
    });
    return metadata;
}

- (void)setMetadata:(NSDictionary *)metadata forKey:(NSString *)key {
    if (!metadata || !key.length) {
        return;
    }
    dispatch_async(_ioQueue, ^{
        NSURL *fileURL = [self.diskCache URLForKey:key];
        [fileURL df_setExtendedAttributeValue:metadata forKey:DFCacheAttributeMetadataKey];
    });
}

- (void)setMetadataValues:(NSDictionary *)keyedValues forKey:(NSString *)key {
    if (!keyedValues.count || !key.length) {
        return;
    }
    dispatch_async(_ioQueue, ^{
        NSURL *fileURL = [self.diskCache URLForKey:key];
        NSDictionary *metadata = [fileURL df_extendedAttributeValueForKey:DFCacheAttributeMetadataKey error:nil];
        NSMutableDictionary *mutableMetadata = [[NSMutableDictionary alloc] initWithDictionary:metadata];
        [mutableMetadata addEntriesFromDictionary:keyedValues];
        [fileURL df_setExtendedAttributeValue:mutableMetadata forKey:DFCacheAttributeMetadataKey];
    });
}

- (void)removeMetadataForKey:(NSString *)key {
    if (!key.length) {
        return;
    }
    dispatch_async(_ioQueue, ^{
        NSURL *fileURL = [self.diskCache URLForKey:key];
        [fileURL df_removeExtendedAttributeForKey:DFCacheAttributeMetadataKey];
    });
}

#pragma mark - Cleanup

- (void)setCleanupTimerInterval:(NSTimeInterval)timeInterval {
    if (_cleanupTimeInterval != timeInterval) {
        _cleanupTimeInterval = timeInterval;
        [self _scheduleCleanupTimer];
    }
}

- (void)setCleanupTimerEnabled:(BOOL)enabled {
    if (_cleanupTimerEnabled != enabled) {
        _cleanupTimerEnabled = enabled;
        [self _scheduleCleanupTimer];
    }
}

- (void)_scheduleCleanupTimer {
    [_cleanupTimer invalidate];
    if (_cleanupTimerEnabled) {
        DFCache *__weak weakSelf = self;
        _cleanupTimer = [DFCacheTimer scheduledTimerWithTimeInterval:_cleanupTimeInterval block:^{
            [weakSelf cleanupDiskCache];
        } userInfo:nil repeats:YES];
    }
}

- (void)cleanupDiskCache {
    dispatch_async(_ioQueue, ^{
        [self.diskCache cleanup];
    });
}

#if (__IPHONE_OS_VERSION_MIN_REQUIRED)
- (void)_didReceiveMemoryWarning:(NSNotification *__unused)notification {
    [self.memoryCache removeAllObjects];
}
#endif

#pragma mark - Data

- (void)cachedDataForKey:(NSString *)key completion:(void (^)(NSData *))completion {
    if (!completion) {
        return;
    }
    if (!key.length) {
        _dwarf_cache_callback(completion, nil);
        return;
    }
    dispatch_async(_ioQueue, ^{
        NSData *data = [self.diskCache dataForKey:key];
        _dwarf_cache_callback(completion, data);
    });
}

- (NSData *)cachedDataForKey:(NSString *)key {
    if (!key.length) {
        return nil;
    }
    NSData *__block data;
    dispatch_sync(_ioQueue, ^{
        data = [self.diskCache dataForKey:key];
    });
    return data;
}

- (void)storeData:(NSData *)data forKey:(NSString *)key {
    if (!data || !key.length) {
        return;
    }
    dispatch_async(_ioQueue, ^{
        [self.diskCache setData:data forKey:key];
    });
}

#pragma mark - Miscellaneous

- (NSString *)debugDescription {
    return [NSString stringWithFormat:@"<%@ %p> { disk_cache = %@ }", [self class], self, [self.diskCache debugDescription]];
}

@end
