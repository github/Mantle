//
//  MAVModel.h
//  Maverick
//
//  Created by Justin Spahr-Summers on 2012-09-11.
//  Copyright (c) 2012 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

//
// An abstract base class for model objects, using reflection to provide
// sensible default behaviors.
//
// Subclasses are assumed to be immutable. If this is not the case,
// -copyWithZone: should be overridden to perform a real copy.
//
// The default implementations of <NSCoding>, -hash, and -isEqual: all make use
// of the dictionaryRepresentation property.
//
@interface MAVModel : NSObject <NSCoding, NSCopying>

// Initializes the receiver using the keys and values in the given dictionary
// (which should correspond to properties on the receiver).
//
// This is the designated initializer for this class.
- (id)initWithDictionary:(NSDictionary *)dict;

// Can be overridden by subclasses to specify default values for properties on
// this class.
//
// The default implementation returns an empty dictionary.
+ (NSDictionary *)defaultValuesForKeys;

// A dictionary representing the properties of the receiver.
//
// The default implementation of this property finds all @property declarations
// (except for those on MAVModel) and combines their values into a dictionary.
// Any nil values will be represented by NSNull.
//
// This property must never return nil.
@property (nonatomic, copy, readonly) NSDictionary *dictionaryRepresentation;

@end
