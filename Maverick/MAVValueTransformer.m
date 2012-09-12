//
//  MAVValueTransformer.m
//  Maverick
//
//  Created by Justin Spahr-Summers on 2012-09-11.
//  Copyright (c) 2012 GitHub. All rights reserved.
//

#import "MAVValueTransformer.h"

//
// Any MAVValueTransformer supporting reverse transformation. Necessary because
// +allowsReverseTransformation is a class method.
//
@interface MAVReversibleValueTransformer : MAVValueTransformer
@end

@interface MAVValueTransformer ()

@property (nonatomic, copy, readonly) MAVValueTransformerBlock forwardBlock;
@property (nonatomic, copy, readonly) MAVValueTransformerBlock reverseBlock;

@end

@implementation MAVValueTransformer

#pragma mark Lifecycle

+ (instancetype)transformerWithBlock:(MAVValueTransformerBlock)transformationBlock {
	return [[self alloc] initWithForwardBlock:transformationBlock reverseBlock:nil];
}

+ (instancetype)reversibleTransformerWithBlock:(MAVValueTransformerBlock)transformationBlock {
	return [self reversibleTransformerWithForwardBlock:transformationBlock reverseBlock:transformationBlock];
}

+ (instancetype)reversibleTransformerWithForwardBlock:(MAVValueTransformerBlock)forwardBlock reverseBlock:(MAVValueTransformerBlock)reverseBlock {
	return [[MAVReversibleValueTransformer alloc] initWithForwardBlock:forwardBlock reverseBlock:reverseBlock];
}

- (id)initWithForwardBlock:(MAVValueTransformerBlock)forwardBlock reverseBlock:(MAVValueTransformerBlock)reverseBlock {
	NSParameterAssert(forwardBlock != nil);

	self = [super init];
	if (self == nil) return nil;

	_forwardBlock = [forwardBlock copy];
	_reverseBlock = [reverseBlock copy];

	return self;
}

#pragma mark NSValueTransformer

+ (BOOL)allowsReverseTransformation {
	return NO;
}

+ (Class)transformedValueClass {
	return [NSObject class];
}

- (id)transformedValue:(id)value {
	return self.forwardBlock(value);
}

@end

@implementation MAVReversibleValueTransformer

#pragma mark Lifecycle

- (id)initWithForwardBlock:(MAVValueTransformerBlock)forwardBlock reverseBlock:(MAVValueTransformerBlock)reverseBlock {
	NSParameterAssert(reverseBlock != nil);
	return [super initWithForwardBlock:forwardBlock reverseBlock:reverseBlock];
}

#pragma mark NSValueTransformer

+ (BOOL)allowsReverseTransformation {
	return YES;
}

- (id)reverseTransformedValue:(id)value {
	return self.reverseBlock(value);
}

@end
