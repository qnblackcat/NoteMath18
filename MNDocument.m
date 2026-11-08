#import "MNDocument.h"
#import "MNFormat.h"
#import "MNLine.h"
#import "MNVariables.h"

@interface MNParagraphInfo : NSObject
@property (nonatomic) NSRange range;     // without the line terminator
@property (nonatomic) NSUInteger end;    // end of the paragraph with its terminator
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *variables; // visible on it
@property (nonatomic) BOOL definition;
@property (nonatomic, strong) NSArray<NSValue *> *names;          // definition line: every name
@property (nonatomic, strong) NSMutableArray<NSValue *> *usedNames; // definition line: the names read below
@property (nonatomic, strong) NSArray<NSValue *> *results;        // calculation line: correct results
@property (nonatomic, strong) NSArray<NSValue *> *readVariables;  // calculation line: the variables they read
@end

@implementation MNParagraphInfo
@end

static NSArray<NSValue *> *shifted(NSArray<NSValue *> *ranges, NSUInteger by) {
	NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:ranges.count];
	for (NSValue *value in ranges) [out addObject:[NSValue valueWithRange:NSMakeRange(value.rangeValue.location + by, value.rangeValue.length)]];
	return out;
}

@implementation MNDocument {
	NSArray<MNParagraphInfo *> *_paragraphs;
	NSDictionary<NSString *, NSNumber *> *_finalVariables;
@public
	unichar _dec, _grp; // the separators the analysis was made with
}

// One pass from the top: variables are followed down the note, and each definition's names wait
// until a correct calculation reads them or a later definition takes the name over.
- (instancetype)initWithText:(NSString *)text {
	if (!(self = [super init])) return nil;
	_text = [text copy];
	MNLoadSeparators(&_dec, &_grp);
	NSString *all = _text;
	NSMutableArray<MNParagraphInfo *> *paragraphs = [NSMutableArray array];
	NSMutableArray<NSValue *> *errors = [NSMutableArray array];
	NSMutableDictionary<NSString *, NSNumber *> *vars = [NSMutableDictionary dictionary];
	__block NSDictionary<NSString *, NSNumber *> *visible = @{};
	__block BOOL hasDefinitions = NO; // shared by the paragraphs until a definition changes it
	NSMutableDictionary<NSString *, MNParagraphInfo *> *owner = [NSMutableDictionary dictionary]; // name -> its current definition line
	NSMutableDictionary<NSString *, NSValue *> *ownerName = [NSMutableDictionary dictionary];      // name -> where it is written there

	[all enumerateSubstringsInRange:NSMakeRange(0, all.length)
		options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
		usingBlock:^(NSString *substring, NSRange paragraph, NSRange enclosing, BOOL *stop) {
		MNParagraphInfo *info = [MNParagraphInfo new];
		info.range = paragraph;
		info.end = NSMaxRange(enclosing);
		info.variables = visible;
		[paragraphs addObject:info];
		if ([all rangeOfString:@"=" options:0 range:paragraph].location == NSNotFound) return;
		NSString *line = [all substringWithRange:paragraph];

		NSArray<NSString *> *names;
		NSArray<NSValue *> *nameRanges;
		if (MNParseDefinitions(line, &names, NULL, &nameRanges)) {
			MNUpdateVariables(vars, line);
			visible = [vars copy];
			info.definition = YES;
			hasDefinitions = YES;
			info.names = shifted(nameRanges, paragraph.location);
			info.usedNames = [NSMutableArray array];
			// A name defined twice on one line: the later one wins, as it does for the value.
			for (NSUInteger k = 0; k < names.count; k++) {
				owner[names[k]] = info;
				ownerName[names[k]] = info.names[k];
			}
			return;
		}

		NSMutableArray<NSValue *> *results = [NSMutableArray array], *variables = [NSMutableArray array], *lineErrors = [NSMutableArray array];
		NSMutableArray<NSString *> *read = [NSMutableArray array];
		MNAnalyzeLine(line, visible, results, variables, read, lineErrors);
		info.results = shifted(results, paragraph.location);
		info.readVariables = shifted(variables, paragraph.location);
		[errors addObjectsFromArray:shifted(lineErrors, paragraph.location)];
		for (NSString *name in read) {
			MNParagraphInfo *definition = owner[name];
			NSValue *written = ownerName[name];
			if (definition && ![definition.usedNames containsObject:written]) [definition.usedNames addObject:written];
		}
	}];

	for (MNParagraphInfo *info in paragraphs) {
		[info.usedNames sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
			return a.rangeValue.location < b.rangeValue.location ? NSOrderedAscending : NSOrderedDescending;
		}];
	}
	_paragraphs = paragraphs;
	_errorRanges = errors;
	_finalVariables = visible;
	_hasDefinitions = hasDefinitions;
	return self;
}

// The paragraph that contains `offset` (its terminator included), or nil past the last one.
- (MNParagraphInfo *)paragraphAt:(NSUInteger)offset {
	NSUInteger lo = 0, hi = _paragraphs.count;
	while (lo < hi) {
		NSUInteger mid = (lo + hi) / 2;
		if (_paragraphs[mid].range.location <= offset) lo = mid + 1;
		else hi = mid;
	}
	if (lo == 0) return nil;
	MNParagraphInfo *info = _paragraphs[lo - 1];
	return offset < info.end ? info : nil;
}

- (NSDictionary<NSString *, NSNumber *> *)variablesAt:(NSUInteger)offset {
	MNParagraphInfo *info = [self paragraphAt:offset];
	if (info) return info.variables;
	return offset >= _paragraphs.lastObject.end ? _finalVariables : @{};
}

- (NSArray<NSValue *> *)coloredRangesInParagraphAt:(NSUInteger)offset {
	MNParagraphInfo *info = [self paragraphAt:offset];
	if (info.definition) return info.usedNames;
	if (!info.results.count) return @[];
	return [info.readVariables arrayByAddingObjectsFromArray:info.results];
}

- (NSArray<NSValue *> *)resultRangesInParagraphAt:(NSUInteger)offset {
	return [self paragraphAt:offset].results ?: @[];
}

- (NSArray<NSValue *> *)usedNameRangesInParagraphAt:(NSUInteger)offset {
	MNParagraphInfo *info = [self paragraphAt:offset];
	return info.definition ? [info.usedNames copy] : @[];
}

- (void)enumerateDefinitionNames:(void (^)(NSRange name, BOOL used))block {
	for (MNParagraphInfo *info in _paragraphs) {
		for (NSValue *name in info.names) block(name.rangeValue, [info.usedNames containsObject:name]);
	}
}

@end

MNDocument *MNDocumentForText(NSString *text) {
	text = text ?: @"";
	// Only the main thread shares the cache; it is where Notes lays out and edits its text.
	if (![NSThread isMainThread]) return [[MNDocument alloc] initWithText:text];
	static MNDocument *last;
	unichar dec, grp;
	MNLoadSeparators(&dec, &grp);
	if (last && last->_dec == dec && last->_grp == grp && last.text.length == text.length && [last.text isEqualToString:text]) return last;
	last = [[MNDocument alloc] initWithText:text];
	return last;
}
