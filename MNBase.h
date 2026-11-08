#import <Foundation/Foundation.h>

// Foundation-only basics shared by every module, so the parser, the formatter and the line
// analysis build on a Mac as well (see Tests/).

// The single debug switch. `make package NOTEMATH_DEBUG=1` defines MN_DEBUG; every debug
// statement goes through MNLog, which compiles to nothing otherwise. The log contains the
// text of the line being edited, so it is never enabled in a release build.
#ifdef MN_DEBUG
#define MNLog(fmt, ...) NSLog(@"[NoteMath18] " fmt, ##__VA_ARGS__)
#else
#define MNLog(fmt, ...) do {} while (0)
#endif

// Character classes shared by the parser and the text helpers.
static inline BOOL isDigit(unichar c) { return c >= '0' && c <= '9'; }
static inline BOOL isLetter(unichar c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static inline BOOL isSpace(unichar c) { return c == ' ' || c == '\t' || c == 0x00A0; }

// Letters of function names and variable names: ASCII plus any other Unicode letter
// (Vietnamese, ...). π is left out because the parser treats it as a constant of its own.
static inline BOOL isWordLetter(unichar c) {
	if (isLetter(c)) return YES;
	if (c < 0x80 || c == 0x03C0) return NO;
	return [[NSCharacterSet letterCharacterSet] characterIsMember:c];
}

// A variable name starts with a letter and goes on with letters, digits and "_".
static inline BOOL isNameChar(unichar c) {
	return isWordLetter(c) || isDigit(c) || c == '_';
}
