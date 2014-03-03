//
//  MTLModel.m
//  Mantle
//
//  Created by Justin Spahr-Summers on 2012-09-11.
//  Copyright (c) 2012 GitHub. All rights reserved.
//

#import "NSError+MTLModelException.h"
#import "NSError+MTLValidation.h"
#import "MTLModel.h"
#import "EXTRuntimeExtensions.h"
#import "EXTScope.h"
#import "MTLReflection.h"
#import <objc/runtime.h>

// This coupling is needed for backwards compatibility in MTLModel's deprecated
// methods.
#import "MTLJSONAdapter.h"
#import "MTLModel+NSCoding.h"

// Used to cache the reflection performed in +propertyKeys.
static void *MTLModelCachedPropertyKeysKey = &MTLModelCachedPropertyKeysKey;

// Validates a value for an object and sets it if necessary.
//
// obj         - The object for which the value is being validated. This value
//               must not be nil.
// key         - The name of one of `obj`s properties. This value must not be
//               nil.
// value       - The new value for the property identified by `key`.
// forceUpdate - If set to `YES`, the value is being updated even if validating
//               it did not change it.
// error       - If not NULL, this may be set to any error that occurs during
//               validation
//
// Returns YES if `value` could be validated and set, or NO if an error
// occurred.
static BOOL MTLValidateAndSetValue(id obj, NSString *key, id value, BOOL forceUpdate, NSError **error) {
	// Mark this as being autoreleased, because validateValue may return
	// a new object to be stored in this variable (and we don't want ARC to
	// double-free or leak the old or new values).
	__autoreleasing id validatedValue = value;

	@try {
		if (![obj validateValue:&validatedValue forKey:key error:error]) return NO;

		if (forceUpdate || value != validatedValue) {
			[obj setValue:validatedValue forKey:key];
		}

		return YES;
	} @catch (NSException *ex) {
		NSLog(@"*** Caught exception setting key \"%@\" : %@", key, ex);

		// Fail fast in Debug builds.
		#if DEBUG
		@throw ex;
		#else
		if (error != NULL) {
			*error = [NSError mtl_modelErrorWithException:ex];
		}

		return NO;
		#endif
	}
}

@interface MTLModel ()

// Enumerates all properties of the receiver's class hierarchy, starting at the
// receiver, and continuing up until (but not including) MTLModel.
//
// The given block will be invoked multiple times for any properties declared on
// multiple classes in the hierarchy.
+ (void)enumeratePropertiesUsingBlock:(void (^)(objc_property_t property, BOOL *stop))block;

@end

@implementation MTLModel

#pragma mark Lifecycle

+ (instancetype)modelWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	return [[self alloc] initWithDictionary:dictionary error:error];
}

+ (instancetype)modelWithDictionary:(NSDictionary *)dictionaryValue options:(MTLParsingOptions)options error:(NSError *__autoreleasing *)error {
	return [[self alloc] initWithDictionary:dictionaryValue options:options error:error];
}

- (instancetype)init {
	// Nothing special by default, but we have a declaration in the header.
	return [super init];
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	return [self initWithDictionary:dictionary options:0 error:error];
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary options:(MTLParsingOptions)options error:(NSError *__autoreleasing *)error {
	self = [self init];
	if (self == nil) return nil;
	
	BOOL shouldIgnoreErrors = (options & MTLParsingOptionCombineValidationErrors) == MTLParsingOptionCombineValidationErrors;
	NSMutableArray *errorsArray = [NSMutableArray array];
	for (NSString *key in dictionary) {
		// Mark this as being autoreleased, because validateValue may return
		// a new object to be stored in this variable (and we don't want ARC to
		// double-free or leak the old or new values).
		__autoreleasing id value = [dictionary objectForKey:key];
		
		if ([value isEqual:NSNull.null]) value = nil;
		
		NSError *validationError = nil;
		if (!MTLValidateAndSetValue(self, key, value, YES, &validationError)) {
			// Validation failed
			if (!shouldIgnoreErrors) {
				// Should also return an error
				if (error) *error = validationError;
				return nil;
			} else if (validationError) {
				// collect errors
				[errorsArray addObject:validationError];
			}
		}
	}
	if ([errorsArray count] && error) *error = [NSError mtl_umbrellaErrorWithErrors:errorsArray];
	return self;
}

#pragma mark Reflection

+ (void)enumeratePropertiesUsingBlock:(void (^)(objc_property_t property, BOOL *stop))block {
	Class cls = self;
	BOOL stop = NO;

	while (!stop && ![cls isEqual:MTLModel.class]) {
		unsigned count = 0;
		objc_property_t *properties = class_copyPropertyList(cls, &count);

		cls = cls.superclass;
		if (properties == NULL) continue;

		@onExit {
			free(properties);
		};

		for (unsigned i = 0; i < count; i++) {
			block(properties[i], &stop);
			if (stop) break;
		}
	}
}

+ (NSSet *)propertyKeys {
	NSSet *cachedKeys = objc_getAssociatedObject(self, MTLModelCachedPropertyKeysKey);
	if (cachedKeys != nil) return cachedKeys;

	NSMutableSet *keys = [NSMutableSet set];

	[self enumeratePropertiesUsingBlock:^(objc_property_t property, BOOL *stop) {
		mtl_propertyAttributes *attributes = mtl_copyPropertyAttributes(property);
		@onExit {
			free(attributes);
		};

		if (attributes->readonly && attributes->ivar == NULL) return;

		NSString *key = @(property_getName(property));
		[keys addObject:key];
	}];

	// It doesn't really matter if we replace another thread's work, since we do
	// it atomically and the result should be the same.
	objc_setAssociatedObject(self, MTLModelCachedPropertyKeysKey, keys, OBJC_ASSOCIATION_COPY);

	return keys;
}

- (NSDictionary *)dictionaryValue {
	return [self dictionaryWithValuesForKeys:self.class.propertyKeys.allObjects];
}

#pragma mark Merging

- (void)mergeValueForKey:(NSString *)key fromModel:(MTLModel *)model {
	NSParameterAssert(key != nil);

	SEL selector = MTLSelectorWithCapitalizedKeyPattern("merge", key, "FromModel:");
	if (![self respondsToSelector:selector]) {
		if (model != nil) {
			[self setValue:[model valueForKey:key] forKey:key];
		}

		return;
	}

	NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:selector]];
	invocation.target = self;
	invocation.selector = selector;

	[invocation setArgument:&model atIndex:2];
	[invocation invoke];
}

- (void)mergeValuesForKeysFromModel:(MTLModel *)model {
	for (NSString *key in self.class.propertyKeys) {
		[self mergeValueForKey:key fromModel:model];
	}
}

#pragma mark Validation

- (BOOL)validate:(NSError **)error {
	for (NSString *key in self.class.propertyKeys) {
		id value = [self valueForKey:key];

		BOOL success = MTLValidateAndSetValue(self, key, value, NO, error);
		if (!success) return NO;
	}

	return YES;
}

- (BOOL)validateValue:(inout __autoreleasing id *)ioValue forKey:(NSString *)inKey error:(out NSError *__autoreleasing *)outError {
	// If super validation failed, don't bother to continue.
	// At this point individual keys are validated
	if (![super validateValue:ioValue forKey:inKey error:outError]) return NO;
	
	// check if object implements validate<Key>:error:
	SEL validateKeySelector = MTLSelectorWithCapitalizedKeyPattern("validate", inKey, ":error:");
	if ([self respondsToSelector:validateKeySelector]) return YES;
	
	// assuming JSONTransformer validating
	if ([self conformsToProtocol:@protocol(MTLJSONSerializing)]) {
		SEL jsonTransformerSelector = MTLSelectorWithKeyPattern(inKey, "JSONTransformer");
		if ([[self class] respondsToSelector:jsonTransformerSelector]) return YES;
	}
		
	if (![self conformsToProtocol:@protocol(MTLTypeValidation)] ||
		![[self class] supportsTypeValidation]) return YES;
	
	// No way to figure out if the value is of the same type as the property
	if (*ioValue == nil) return YES;
	
	objc_property_t property = class_getProperty([self class], [inKey UTF8String]);
	mtl_propertyAttributes *attributes = mtl_copyPropertyAttributes(property);
	@onExit {
		free(attributes);
	};
	
	Class propertyClass = attributes->objectClass;
	Class valueClass = [*ioValue class];
	
	if (propertyClass != nil && valueClass != nil) {
		if ([valueClass isSubclassOfClass:propertyClass]) return YES;
		if (outError != nil) *outError = [NSError mtl_validationErrorForProperty:inKey
																	expectedType:NSStringFromClass(propertyClass)
																	receivedType:NSStringFromClass(valueClass)];
		return NO;
	}
	
	// the value expected to contain a boxed structure
	if ([valueClass isSubclassOfClass:[NSValue class]]) return YES;
	
	if (outError != nil) *outError = [NSError mtl_validationErrorForProperty:inKey
																expectedType:[NSString stringWithFormat:@"%s", attributes->type]
																receivedType:NSStringFromClass(valueClass)];

	return NO;
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
	return [[self.class allocWithZone:zone] initWithDictionary:self.dictionaryValue error:NULL];
}

#pragma mark NSObject

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p> %@", self.class, self, self.dictionaryValue];
}

- (NSUInteger)hash {
	NSUInteger value = 0;

	for (NSString *key in self.class.propertyKeys) {
		value ^= [[self valueForKey:key] hash];
	}

	return value;
}

- (BOOL)isEqual:(MTLModel *)model {
	if (self == model) return YES;
	if (![model isMemberOfClass:self.class]) return NO;

	for (NSString *key in self.class.propertyKeys) {
		id selfValue = [self valueForKey:key];
		id modelValue = [model valueForKey:key];

		BOOL valuesEqual = ((selfValue == nil && modelValue == nil) || [selfValue isEqual:modelValue]);
		if (!valuesEqual) return NO;
	}

	return YES;
}

@end
