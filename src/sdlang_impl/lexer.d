﻿/// SDLang-D
/// Written in the D programming language.

module sdlang_impl.lexer;

import std.array;
import std.base64;
import std.bigint;
import std.conv;
import std.datetime;
import std.stream : ByteOrderMarks, BOM;
import std.typecons;
import std.uni;
import std.utf;
import std.variant;

import sdlang_impl.exception;
import sdlang_impl.symbol;
import sdlang_impl.token;
import sdlang_impl.util;

alias sdlang_impl.util.startsWith startsWith;

// Kind of a poor-man's yield, but fast.
// Only to be used inside Lexer.popFront.
private template accept(string symbolName)
{
	static assert(symbolName != "Value", "Value symbols must also take a value.");
	enum accept = acceptImpl!(symbolName, "null");
}
private template accept(string symbolName, string value)
{
	static assert(symbolName == "Value", "Only a Value symbol can take a value.");
	enum accept = acceptImpl!(symbolName, value);
}
private template accept(string symbolName, string value, string startLocation, string endLocation)
{
	static assert(symbolName == "Value", "Only a Value symbol can take a value.");
	enum accept = ("
		{
			_front = makeToken!"~symbolName.stringof~";
			_front.value = "~value~";
			_front.location = "~(startLocation==""? "tokenStart" : startLocation)~";
			_front.data = source[
				"~(startLocation==""? "tokenStart.index" : startLocation)~"
				..
				"~(endLocation==""? "location.index" : endLocation)~"
			];
			return;
		}
	").replace("\n", "");
}
private template acceptImpl(string symbolName, string value)
{
	enum acceptImpl = ("
		{
			_front = makeToken!"~symbolName.stringof~";
			_front.value = "~value~";
			return;
		}
	").replace("\n", "");
}
///.
class Lexer
{
	string source; ///.
	Location location; /// Location of current character in source

	private dchar  ch;         // Current character
	private dchar  nextCh;     // Lookahead character
	private size_t nextPos;    // Position of lookahead character (an index into source)
	private bool   hasNextCh;  // If false, then there's no more lookahead, just EOF
	private size_t posAfterLookahead; // Position after lookahead character (an index into source)

	private Location tokenStart;    // The starting location of the token being lexed
	
	// Length so far of the token being lexed, not including current char
	private size_t tokenLength;   // Length in UTF-8 code units
	private size_t tokenLength32; // Length in UTF-32 code units
	
	///.
	this(string source=null, string filename=null)
	{
		_front = Token(symbol!"Error", Location());

		if( source.startsWith( ByteOrderMarks[BOM.UTF8] ) )
			source = source[ ByteOrderMarks[BOM.UTF8].length .. $ ];
		
		foreach(bom; ByteOrderMarks)
		if( source.startsWith(bom) )
			error(Location(filename,0,0,0), "SDL spec only supports UTF-8, not UTF-16 or UTF-32");

		this.source = source;
		
		// Prime everything
		hasNextCh = true;
		nextCh = source.decode(posAfterLookahead);
		advanceChar(ErrorOnEOF.Yes); //TODO: Emit EOF on parsing empty string
		location = Location(filename, 0, 0, 0);
		popFront();
	}
	
	///.
	@property bool empty()
	{
		return _front.symbol == symbol!"EOF";
	}
	
	///.
	Token _front;
	@property Token front()
	{
		return _front;
	}

	///.
	@property bool isEOF()
	{
		return location.index == source.length;
	}

	private void error(string msg)
	{
		error(location, msg);
	}

	private void error(Location loc, string msg)
	{
		throw new SDLangException(loc, "Error: "~msg);
	}

	private Token makeToken(string symbolName)()
	{
		auto tok = Token(symbol!symbolName, tokenStart);
		tok.data = tokenData;
		return tok;
	}
	
	private @property string tokenData()
	{
		return source[ tokenStart.index .. location.index ];
	}
	
	/// Check the lookahead character
	private bool lookahead(dchar ch)
	{
		return hasNextCh && nextCh == ch;
	}

	private bool isNewline(dchar ch)
	{
		//TODO: Not entirely sure if this list is 100% complete and correct per spec.
		return ch == '\n' || ch == '\r' || ch == lineSep || ch == paraSep;
	}

	/// Is 'ch' a valid base 64 character?
	private bool isBase64(dchar ch)
	{
		if(ch >= 'A' && ch <= 'Z')
			return true;

		if(ch >= 'a' && ch <= 'z')
			return true;

		if(ch >= '0' && ch <= '9')
			return true;
		
		return ch == '+' || ch == '/' || ch == '=';
	}
	
	/// Is current character the last one in an ident?
	private bool isEndOfIdentCached = false;
	private bool _isEndOfIdent;
	private bool isEndOfIdent()
	{
		if(!isEndOfIdentCached)
		{
			if(!hasNextCh)
				_isEndOfIdent = true;
			else
				_isEndOfIdent = !isIdentChar(nextCh);
			
			isEndOfIdentCached = true;
		}
		
		return _isEndOfIdent;
	}

	/// Is 'ch' a character that's allowed *somewhere* in an identifier?
	private bool isIdentChar(dchar ch)
	{
		if(isAlpha(ch))
			return true;
		
		else if(isNumber(ch))
			return true;
		
		else
			return 
				ch == '-' ||
				ch == '_' ||
				ch == '.' ||
				ch == '$';
	}

	private bool isDigit(dchar ch)
	{
		return ch >= '0' && ch <= '9';
	}
	
	private enum KeywordResult
	{
		Accept,   // Keyword is matched
		Continue, // Keyword is not matched *yet*
		Failed,   // Keyword doesn't match
	}
	private KeywordResult checkKeyword(dstring keyword32)
	{
		// Still within length of keyword
		if(tokenLength32 < keyword32.length)
		{
			if(ch == keyword32[tokenLength32])
				return KeywordResult.Continue;
			else
				return KeywordResult.Failed;
		}

		// At position after keyword
		else if(tokenLength32 == keyword32.length)
		{
			if(!isIdentChar(ch))
			{
				debug assert(tokenData == to!string(keyword32));
				return KeywordResult.Accept;
			}
			else
				return KeywordResult.Failed;
		}

		assert(0, "Fell off end of keyword to check");
	}

	enum ErrorOnEOF { No, Yes }

	/// Advance one code point.
	/// Returns false if EOF was reached
	private void advanceChar(ErrorOnEOF errorOnEOF)
	{
		//TODO: Should this include all isNewline()? (except for \r, right?)
		if(ch == '\n')
		{
			location.line++;
			location.col = 0;
		}
		else
			location.col++;

		location.index = nextPos;

		nextPos = posAfterLookahead;
		ch      = nextCh;

		if(!hasNextCh)
		{
			if(errorOnEOF == ErrorOnEOF.Yes)
				error("Unexpected end of file");

			return;
		}

		if(nextPos == source.length)
		{
			nextCh = dchar.init;
			hasNextCh = false;
			return;
		}

		tokenLength32++;
		tokenLength = location.index - tokenStart.index;
		
		nextCh = source.decode(posAfterLookahead);
		isEndOfIdentCached = false;
	}

	///.
	void popFront()
	{
		// -- Main Lexer -------------

		eatWhite();

		if(isEOF)
			mixin(accept!"EOF");
		
		tokenStart    = location;
		tokenLength   = 0;
		tokenLength32 = 0;
		isEndOfIdentCached = false;
		
		if(ch == '=')
		{
			advanceChar(ErrorOnEOF.No);
			mixin(accept!"=");
		}
		
		else if(ch == '{')
		{
			advanceChar(ErrorOnEOF.No);
			mixin(accept!"{");
		}
		
		else if(ch == '}')
		{
			advanceChar(ErrorOnEOF.No);
			mixin(accept!"}");
		}
		
		else if(ch == ':')
		{
			advanceChar(ErrorOnEOF.No);
			mixin(accept!":");
		}
		
		//TODO: Should this include all isNewline()? (except for \r, right?)
		else if(ch == ';' || ch == '\n')
		{
			advanceChar(ErrorOnEOF.No);
			mixin(accept!"EOL");
		}
		
		else if(isAlpha(ch) || ch == '_')
			lexIdentKeyword();

		else if(ch == '"')
			lexRegularString();

		else if(ch == '`')
			lexRawString();
		
		else if(ch == '\'')
			lexCharacter();

		else if(ch == '[')
			lexBinary();

		else if(ch == '-' || ch == '.' || isDigit(ch))
			lexNumeric();

		else
		{
			advanceChar(ErrorOnEOF.No);
			mixin(accept!"Error");
		}
	}

	/// Lex Ident or Keyword
	private void lexIdentKeyword()
	{
		assert(isAlpha(ch) || ch == '_');
		
		// Keyword
		struct Key
		{
			dstring name;
			Value value;
			bool failed = false;
		}
		static Key[5] keywords;
		static keywordsInited = false;
		if(!keywordsInited)
		{
			// Value (as a std.variant-based type) can't be statically inited
			keywords[0] = Key("true",  Value(true ));
			keywords[1] = Key("false", Value(false));
			keywords[2] = Key("on",    Value(true ));
			keywords[3] = Key("off",   Value(false));
			keywords[4] = Key("null",  Value(null ));
			keywordsInited = true;
		}
		
		foreach(ref key; keywords)
			key.failed = false;
		
		auto numKeys = keywords.length;

		do
		{
			foreach(ref key; keywords)
			if(!key.failed)
			{
				final switch(checkKeyword(key.name))
				{
				case KeywordResult.Accept:
					mixin(accept!("Value", "key.value"));
				
				case KeywordResult.Continue:
					break;
				
				case KeywordResult.Failed:
					key.failed = true;
					numKeys--;
					break;
				}
			}

			if(numKeys == 0)
			{
				lexIdent();
				return;
			}

			advanceChar(ErrorOnEOF.No);

		} while(!isEOF);

		mixin(accept!"Ident");
	}

	/// Lex Ident
	private void lexIdent()
	{
		if(tokenLength == 0)
			assert(isAlpha(ch) || ch == '_');
		
		while(!isEOF && isIdentChar(ch))
			advanceChar(ErrorOnEOF.No);

		mixin(accept!"Ident");
	}
	
	/// Lex regular string
	private void lexRegularString()
	{
		assert(ch == '"');

		Appender!string buf;
		size_t spanStart = nextPos;
		
		// Doesn't include current character
		void updateBuf()
		{
			if(location.index == spanStart)
				return;

			buf.put( source[spanStart..location.index] );
		}
		
		do
		{
			advanceChar(ErrorOnEOF.Yes);

			if(ch == '\\')
			{
				updateBuf();
				
				advanceChar(ErrorOnEOF.Yes);
				if(isNewline(ch))
					eatWhite();
				else
				{
					//TODO: Is this list of escape chars 100% complete and correct?
					switch(ch)
					{
					case 'n': buf.put('\n'); break;
					case 't': buf.put('\t'); break;
					
					// Handles ' " \ and anything else
					default: buf.put(ch); break;
					}

					advanceChar(ErrorOnEOF.Yes);
				}
				spanStart = location.index;
			}

			else if(isNewline(ch))
				error("Unescaped newlines are only allowed in raw strings, not regular strings.");

		} while(ch != '"');
		
		updateBuf();
		advanceChar(ErrorOnEOF.No); // Skip closing double-quote
		mixin(accept!("Value", "buf.data"));
	}

	/// Lex raw string
	private void lexRawString()
	{
		assert(ch == '`');
		
		do
			advanceChar(ErrorOnEOF.Yes);
		while(ch != '`');
		
		advanceChar(ErrorOnEOF.No); // Skip closing back-tick
		mixin(accept!("Value", "tokenData[1..$-1]"));
	}
	
	/// Lex character literal
	private void lexCharacter()
	{
		assert(ch == '\'');
		advanceChar(ErrorOnEOF.Yes); // Skip opening single-quote
		
		auto value = ch;
		advanceChar(ErrorOnEOF.Yes); // Skip the character itself

		if(ch == '\'')
			advanceChar(ErrorOnEOF.No); // Skip closing single-quote
		else
			error("Expected closing single-quote.");

		mixin(accept!("Value", "value"));
	}
	
	/// Lex base64 binary literal
	private void lexBinary()
	{
		assert(ch == '[');
		advanceChar(ErrorOnEOF.Yes);
		
		void eatBase64Whitespace()
		{
			while(!isEOF && isWhite(ch))
			{
				if(isNewline(ch))
					advanceChar(ErrorOnEOF.Yes);
				
				if(!isEOF && isWhite(ch))
					eatWhite();
			}
		}
		
		eatBase64Whitespace();

		// Iterates all valid base64 characters, ending at ']'.
		// Skips all whitespace. Throws on invalid chars.
		struct Base64InputRange
		{
			Lexer *lexer;
			
			@property bool empty()
			{
				return lexer.ch == ']';
			}

			@property dchar front()
			{
				return lexer.ch;
			}
			
			void popFront()
			{
				auto lex = lexer;
				lex.advanceChar(lex.ErrorOnEOF.Yes);

				eatBase64Whitespace();
				
				if(lex.isEOF)
					lex.error("Unexpected end of file.");

				if(lex.ch != ']' && !lex.isBase64(lex.ch))
					lex.error("Invalid character in base64 binary literal.");
			}
		}
		
		// This is a slow ugly hack. It's necessary because Base64.decode
		// currently requires the source to have known length.
		//TODO: Remove this when DMD issue #9543 is fixed.
		dchar[] tmpBuf = array(Base64InputRange(&this));

		Appender!(ubyte[]) outputBuf;
		// Ugly workaround for DMD issue #9102
		//TODO: Remove this when DMD #9102 is fixed
		struct OutputBuf
		{
			void put(ubyte ch)
			{
				outputBuf.put(ch);
			}
		}
		
		try
			//Base64.decode(Base64InputRange(&this), OutputBuf());
			Base64.decode(tmpBuf, OutputBuf());

		//TODO: Starting with dmd 2.062, this should be a Base64Exception
		catch(Exception e)
			error("Invalid character in base64 binary literal.");
		
		advanceChar(ErrorOnEOF.No); // Skip ']'
		mixin(accept!("Value", "outputBuf.data"));
	}
	
	private BigInt toBigInt(bool isNegative, string absValue)
	{
		auto num = BigInt(absValue);
		assert(num > 0);

		if(isNegative)
			num = -num;

		return num;
	}

	/// Lex [0-9]+, but without emitting a token.
	/// This is used by the other numeric parsing functions.
	private string lexNumericFragment()
	{
		if(!isDigit(ch))
			error("Expected a digit 0-9.");
		
		auto spanStart = location.index;
		
		do
		{
			advanceChar(ErrorOnEOF.No);
		} while(!isEOF && isDigit(ch));
		
		return source[spanStart..location.index];
	}

	/// Lex anything that starts with 0-9 or '-'. Ints, floats, dates, etc.
	private void lexNumeric()
	{
		assert(ch == '-' || ch == '.' || isDigit(ch));

		// Check for negative
		bool isNegative = ch == '-';
		if(isNegative)
			advanceChar(ErrorOnEOF.Yes);

		// Some floating point with omitted leading zero?
		if(ch == '.')
		{
			lexFloatingPoint("");
			return;
		}
		
		auto numStr = lexNumericFragment();
		
		// Long integer (64-bit signed)?
		if(ch == 'L' || ch == 'l')
		{
			advanceChar(ErrorOnEOF.No);

			// BigInt(long.min) is a workaround for DMD issue #9548
			auto num = toBigInt(isNegative, numStr);
			if(num < BigInt(long.min) || num > long.max)
				error(tokenStart, "Value doesn't fit in 64-bit signed long integer: "~to!string(num));

			mixin(accept!("Value", "num.toLong()"));
		}
		
		// Some floating point?
		else if(ch == '.')
			lexFloatingPoint(numStr);
		
		// Some date?
		else if(ch == '/')
			lexDate(isNegative, numStr);
		
		// Some time span?
		else if(ch == ':' || ch == 'd')
			lexTimeSpan(isNegative, numStr);

		// Integer (32-bit signed)
		else
		{
			auto num = toBigInt(isNegative, numStr);
			if(num < int.min || num > int.max)
				error(tokenStart, "Value doesn't fit in 32-bit signed integer: "~to!string(num));

			mixin(accept!("Value", "num.toInt()"));
		}
	}
	
	/// Lex any floating-point literal (after the initial numeric fragment was lexed)
	private void lexFloatingPoint(string firstPart)
	{
		assert(ch == '.');
		advanceChar(ErrorOnEOF.No);
		
		auto secondPart = lexNumericFragment();
		
		//TODO: How does spec handle invalid suffix like "1.23a" or "1.23bda"?
		//      An error? Or a value and ident? (An "unexpected token EOL"?!?)

		try
		{
			// Float (32-bit signed)?
			if(ch == 'F' || ch == 'f')
			{
				auto value = to!float(tokenData);
				advanceChar(ErrorOnEOF.No);
				mixin(accept!("Value", "value"));
			}

			// Double float (64-bit signed) with suffix?
			else if(ch == 'D' || ch == 'd')
			{
				auto value = to!double(tokenData);
				advanceChar(ErrorOnEOF.No);
				mixin(accept!("Value", "value"));
			}

			// Decimal (128+ bits signed)?
			else if(ch == 'B' || ch == 'b')
			{
				auto value = to!real(tokenData);
				advanceChar(ErrorOnEOF.Yes);
				if(ch == 'D' || ch == 'd')
				{
					advanceChar(ErrorOnEOF.No);
					mixin(accept!("Value", "value"));
				}

				else
					error("Invalid floating point suffix.");
			}

			// Double float (64-bit signed) without suffix
			else
			{
				auto value = to!double(tokenData);
				mixin(accept!("Value", "value"));
			}
		}
		catch(ConvException e)
			error("Invalid floating point literal.");
	}

	private Date makeDate(bool isNegative, string yearStr, string monthStr, string dayStr)
	{
		BigInt biTmp;
		
		biTmp = BigInt(yearStr);
		if(isNegative)
			biTmp = -biTmp;
		if(biTmp < int.min || biTmp > int.max)
			error(tokenStart, "Date's year is out of range. (Must fit within a 32-bit signed int.)");
		auto year = biTmp.toInt();

		biTmp = BigInt(monthStr);
		if(biTmp < 1 || biTmp > 12)
			error(tokenStart, "Date's month is out of range.");
		auto month = biTmp.toInt();
		
		biTmp = BigInt(dayStr);
		if(biTmp < 1 || biTmp > 31)
			error(tokenStart, "Date's month is out of range.");
		auto day = biTmp.toInt();
		
		return Date(year, month, day);
	}
	
	// TimeOfDay plus milliseconds
	private struct TimeWithFracSec
	{
		TimeOfDay timeOfDay;
		FracSec fracSec;
	}
	private TimeWithFracSec makeTimeWithFracSec(
		bool isNegative, string hourStr, string minuteStr,
		string secondStr, string millisecondStr
	)
	{
		BigInt biTmp;

		biTmp = BigInt(hourStr);
		if(isNegative)
			biTmp = -biTmp;
		if(biTmp < int.min || biTmp > int.max)
			error(tokenStart, "Datetime's hour is out of range.");
		auto hour = biTmp.toInt();
		
		biTmp = BigInt(minuteStr);
		if(biTmp < 0 || biTmp > int.max)
			error(tokenStart, "Datetime's minute is out of range.");
		auto minute = biTmp.toInt();
		
		int second = 0;
		if(secondStr != "")
		{
			biTmp = BigInt(secondStr);
			if(biTmp < 0 || biTmp > int.max)
				error(tokenStart, "Datetime's second is out of range.");
			second = biTmp.toInt();
		}
		
		int millisecond = 0;
		if(millisecondStr != "")
		{
			biTmp = BigInt(millisecondStr);
			if(biTmp < 0 || biTmp > int.max)
				error(tokenStart, "Datetime's millisecond is out of range.");
			millisecond = biTmp.toInt();
		}

		FracSec fracSecs;
		fracSecs.msecs = millisecond;
		
		return TimeWithFracSec(TimeOfDay(hour, minute, second), fracSecs);
	}

	private Duration makeDuration(
		bool isNegative, string dayStr,
		string hourStr, string minuteStr, string secondStr,
		string millisecondStr
	)
	{
		BigInt biTmp;

		long day = 0;
		if(dayStr != "")
		{
			biTmp = BigInt(dayStr);
			if(biTmp < long.min || biTmp > long.max)
				error(tokenStart, "Time span's day is out of range.");
			day = biTmp.toLong();
		}

		biTmp = BigInt(hourStr);
		if(biTmp < long.min || biTmp > long.max)
			error(tokenStart, "Time span's hour is out of range.");
		auto hour = biTmp.toLong();

		biTmp = BigInt(minuteStr);
		if(biTmp < long.min || biTmp > long.max)
			error(tokenStart, "Time span's minute is out of range.");
		auto minute = biTmp.toLong();

		biTmp = BigInt(secondStr);
		if(biTmp < long.min || biTmp > long.max)
			error(tokenStart, "Time span's second is out of range.");
		auto second = biTmp.toLong();

		long millisecond = 0;
		if(millisecondStr != "")
		{
			biTmp = BigInt(millisecondStr);
			if(biTmp < long.min || biTmp > long.max)
				error(tokenStart, "Time span's millisecond is out of range.");
			millisecond = biTmp.toLong();
		}
		
		auto duration =
			dur!"days"   (day)    +
			dur!"hours"  (hour)   +
			dur!"minutes"(minute) +
			dur!"seconds"(second) +
			dur!"msecs"  (millisecond);

		if(isNegative)
			duration = -duration;
		
		return duration;
	}

	/// Lex date or datetime (after the initial numeric fragment was lexed)
	//TODO: How does the spec handle a date (not datetime) followed by an int? As a date (not datetime) followed by an int
	private void lexDate(bool isDateNegative, string yearStr)
	{
		assert(ch == '/');
		
		// Lex months
		advanceChar(ErrorOnEOF.Yes); // Skip '/'
		auto monthStr = lexNumericFragment();

		// Lex days
		if(ch != '/')
			error("Invalid date format: Missing days.");
		advanceChar(ErrorOnEOF.Yes); // Skip '/'
		auto dayStr = lexNumericFragment();
		
		auto date = makeDate(isDateNegative, yearStr, monthStr, dayStr);

		// Date?
		if(isEOF)
			mixin(accept!("Value", "date"));
		
		auto endOfDate = location;
		
		while(!isEOF && isWhite(ch) && !isNewline(ch))
			advanceChar(ErrorOnEOF.No);

		// Date?
		if(isEOF || !isDigit(ch))
			mixin(accept!("Value", "date", "", "endOfDate.index"));
		
		// Is time negative?
		bool isTimeNegative = ch == '-';
		if(isTimeNegative)
			advanceChar(ErrorOnEOF.Yes);

		// Lex hours
		auto hourStr = lexNumericFragment();
		
		// Lex minutes
		if(ch != ':')
		{
			//TODO: This really shouldn't be an error. It should be
			//      "accept the plain Date, and then continue lexing normally from there."
			error("Invalid date-time format: Missing minutes.");
		}
		advanceChar(ErrorOnEOF.Yes); // Skip ':'
		auto minuteStr = lexNumericFragment();
		
		// Lex seconds, if exists
		string secondStr;
		if(ch == ':')
		{
			advanceChar(ErrorOnEOF.Yes); // Skip ':'
			secondStr = lexNumericFragment();
		}
		
		// Lex milliseconds, if exists
		string millisecondStr;
		if(ch == '.')
		{
			advanceChar(ErrorOnEOF.Yes); // Skip '.'
			millisecondStr = lexNumericFragment();
		}

		auto timeWithFracSec = makeTimeWithFracSec(isTimeNegative, hourStr, minuteStr, secondStr, millisecondStr);
		auto dateTime = DateTime(date, timeWithFracSec.timeOfDay);
		
		// Lex zone, if exists
		if(ch == '-')
		{
			advanceChar(ErrorOnEOF.Yes); // Skip '-'
			auto timezoneStart = location;
			
			if(!isAlpha(ch))
				error("Invalid timezone format.");
			
			while(!isEOF && !isWhite(ch))
				advanceChar(ErrorOnEOF.No);
			
			auto timezoneStr = source[timezoneStart.index..location.index];

			// Why the fuck is SimpleTimeZone.fromISOString private?!?! Fucking API minimalism...
			if(timezoneStr.startsWith("GMT"))
			{
				auto isoPart = timezoneStr["GMT".length..$];
				if(isoPart.length == 3 || isoPart.length == 6)
				if(isoPart[0] == '+' || isoPart[0] == '-')
				{
					auto isNegative = isoPart[0] == '-';

					auto numHours = to!long(isoPart[1..3]);
					long numMinutes = 0;
					if(isoPart.length == 6)
						numMinutes = to!long(isoPart[4..$]);

					auto timeZoneOffset = hours(numHours) + minutes(numMinutes);
					if(isNegative)
						timeZoneOffset = -timeZoneOffset;

					auto timezone = new SimpleTimeZone(timeZoneOffset);
					mixin(accept!("Value", "SysTime(dateTime, timeWithFracSec.fracSec, timezone)"));
				}
			}
			
			try
			{
				auto timezone = TimeZone.getTimeZone(timezoneStr);
				if(timezone)
					mixin(accept!("Value", "SysTime(dateTime, timeWithFracSec.fracSec, timezone)"));
			}
			catch(TimeException e)
			{
				// Time zone not found. So just move along to "Unknown time zone" below.
			}

			// Unknown time zone
			mixin(accept!("Value", "DateTimeFracUnknownZone(dateTime, timeWithFracSec.fracSec, timezoneStr)"));
		}
		else
			mixin(accept!("Value", "DateTimeFrac(dateTime, timeWithFracSec.fracSec)"));
	}

	/// Lex time span (after the initial numeric fragment was lexed)
	private void lexTimeSpan(bool isNegative, string firstPart)
	{
		assert(ch == ':' || ch == 'd');
		
		string dayStr = "";
		string hourStr;

		// Lexed days?
		bool hasDays = ch == 'd';
		if(hasDays)
		{
			dayStr = firstPart;
			advanceChar(ErrorOnEOF.Yes); // Skip 'd'

			// Lex hours
			if(ch != ':')
				error("Invalid time span format: Missing hours.");
			advanceChar(ErrorOnEOF.Yes); // Skip ':'
			hourStr = lexNumericFragment();
		}
		else
			hourStr = firstPart;

		// Lex minutes
		if(ch != ':')
			error("Invalid time span format: Missing minutes.");
		advanceChar(ErrorOnEOF.Yes); // Skip ':'
		auto minuteStr = lexNumericFragment();

		// Lex seconds
		if(ch != ':')
			error("Invalid time span format: Missing seconds.");
		advanceChar(ErrorOnEOF.Yes); // Skip ':'
		auto secondStr = lexNumericFragment();
		
		// Lex milliseconds, if exists
		string millisecondStr = "";
		if(ch == '.')
		{
			advanceChar(ErrorOnEOF.Yes); // Skip '.'
			millisecondStr = lexNumericFragment();
		}
		
		auto duration = makeDuration(isNegative, dayStr, hourStr, minuteStr, secondStr, millisecondStr);
		mixin(accept!("Value", "duration"));
	}

	/// Advances past whitespace and comments
	private void eatWhite()
	{
		// -- Comment/Whitepace Lexer -------------

		enum State
		{
			normal,
			backslash,    // Got "\\", Eating whitespace until "\n"
			lineComment,  // Got "#" or "//" or "--", Eating everything until "\n"
			blockComment, // Got "/*", Eating everything until "*/"
		}

		if(isEOF)
			return;
		
		Location commentStart;
		State state = State.normal;
		while(true)
		{
			final switch(state)
			{
			case State.normal:

				if(ch == '\\')
				{
					commentStart = location;
					state = State.backslash;
				}

				else if(ch == '#')
				{
					commentStart = location;
					state = State.lineComment;
				}

				else if(ch == '/' || ch == '-')
				{
					commentStart = location;
					if(lookahead(ch))
					{
						advanceChar(ErrorOnEOF.No);
						state = State.lineComment;
					}
					else if(ch == '/' && lookahead('*'))
					{
						advanceChar(ErrorOnEOF.No);
						state = State.blockComment;
					}
					else
						return; // Done
				}
				//TODO: Should this include all isNewline()? (except for \r, right?)
				else if(ch == '\n' || !isWhite(ch))
					return; // Done

				break;
			
			case State.backslash:
				//TODO: Should this include all isNewline()? (except for \r, right?)
				if(ch == '\n')
					state = State.normal;
				else if(!isWhite(ch))
					error("Only whitespace can come after a line-continuation backslash.");
				break;
			
			case State.lineComment:
				//TODO: Should this include all isNewline()? (except for \r, right?)
				if(lookahead('\n'))
					state = State.normal;
				break;
			
			case State.blockComment:
				if(ch == '*')
				{
					if(lookahead('/'))
					{
						advanceChar(ErrorOnEOF.No);
						state = State.normal;
					}
					else
						return; // Done
				}
				break;
			}
			
			advanceChar(ErrorOnEOF.No);
			if(isEOF)
			{
				// Reached EOF

				if(state == State.backslash)
					error("Missing newline after line-continuation backslash.");

				else if(state == State.blockComment)
					error(commentStart, "Unterminated block comment.");

				else
					return; // Done, reached EOF
			}
		}
	}
}

version(unittest_sdlang)
unittest
{
	import std.stdio;
	writeln("Unittesting sdlang lexer...");
	
	auto loc  = Location("filename", 0, 0, 0);
	auto loc2 = Location("a", 1, 1, 1);
	assert([Token(symbol!"EOL",loc)             ] == [Token(symbol!"EOL",loc)              ] );
	assert([Token(symbol!"EOL",loc,Value(7),"A")] == [Token(symbol!"EOL",loc2,Value(7),"B")] );

	int numErrors = 0;
	void testLex(string file=__FILE__, size_t line=__LINE__)(string source, Token[] expected)
	{
		auto lexer = new Lexer(source, "filename");
		auto actual = array(lexer);
		if(actual != expected)
		{
			numErrors++;
			stderr.writeln(file, "(", line, "): testLex failed on: ", source);
			stderr.writeln("    Actual:");
			stderr.writeln("    ", actual);
			stderr.writeln("    Expected:");
			stderr.writeln("    ", expected);
		}
	}

	//testLex("", []);
	testLex(":",  [ Token(symbol!":",  loc) ]);
	testLex("=",  [ Token(symbol!"=",  loc) ]);
	testLex("{",  [ Token(symbol!"{",  loc) ]);
	testLex("}",  [ Token(symbol!"}",  loc) ]);
	testLex(";",  [ Token(symbol!"EOL",loc) ]);
	testLex("\n", [ Token(symbol!"EOL",loc) ]);

	testLex("foo", [ Token(symbol!"Ident",loc,Value(null),"foo") ]);
	testLex("foo bar", [
		Token(symbol!"Ident",loc,Value(null),"foo"),
		Token(symbol!"Ident",loc,Value(null),"bar"),
	]);

	testLex("foo : = { } ; \n bar \n", [
		Token(symbol!"Ident",loc,Value(null),"foo"),
		Token(symbol!":",loc),
		Token(symbol!"=",loc),
		Token(symbol!"{",loc),
		Token(symbol!"}",loc),
		Token(symbol!"EOL",loc),
		Token(symbol!"EOL",loc),
		Token(symbol!"Ident",loc,Value(null),"bar"),
		Token(symbol!"EOL",loc),
	]);

	// Integers
	testLex(  "7", [ Token(symbol!"Value",loc,Value(cast( int) 7)) ]);
	testLex( "-7", [ Token(symbol!"Value",loc,Value(cast( int)-7)) ]);
	testLex( "7L", [ Token(symbol!"Value",loc,Value(cast(long) 7)) ]);
	testLex( "7l", [ Token(symbol!"Value",loc,Value(cast(long) 7)) ]);
	testLex("-7L", [ Token(symbol!"Value",loc,Value(cast(long)-7)) ]);

	// Floats
	testLex("1.2F" , [ Token(symbol!"Value",loc,Value(cast( float)1.2)) ]);
	testLex("1.2f" , [ Token(symbol!"Value",loc,Value(cast( float)1.2)) ]);
	testLex("1.2"  , [ Token(symbol!"Value",loc,Value(cast(double)1.2)) ]);
	testLex("1.2D" , [ Token(symbol!"Value",loc,Value(cast(double)1.2)) ]);
	testLex("1.2d" , [ Token(symbol!"Value",loc,Value(cast(double)1.2)) ]);
	testLex("1.2BD", [ Token(symbol!"Value",loc,Value(cast(  real)1.2)) ]);
	testLex("1.2bd", [ Token(symbol!"Value",loc,Value(cast(  real)1.2)) ]);
	testLex("1.2Bd", [ Token(symbol!"Value",loc,Value(cast(  real)1.2)) ]);
	testLex("1.2bD", [ Token(symbol!"Value",loc,Value(cast(  real)1.2)) ]);

	// Booleans and null
	testLex("true",  [ Token(symbol!"Value",loc,Value( true)) ]);
	testLex("false", [ Token(symbol!"Value",loc,Value(false)) ]);
	testLex("on",    [ Token(symbol!"Value",loc,Value( true)) ]);
	testLex("off",   [ Token(symbol!"Value",loc,Value(false)) ]);
	testLex("TRUE",  [ Token(symbol!"Ident",loc,Value( null),"TRUE") ]);
	testLex("null",  [ Token(symbol!"Value",loc,Value( null)) ]);

	// Raw Backtick Strings
	testLex("`hello world`",     [ Token(symbol!"Value",loc,Value(`hello world`   )) ]);
	testLex("` hello world `",   [ Token(symbol!"Value",loc,Value(` hello world ` )) ]);
	testLex("`hello \\t world`", [ Token(symbol!"Value",loc,Value(`hello \t world`)) ]);
	testLex("`hello \\n world`", [ Token(symbol!"Value",loc,Value(`hello \n world`)) ]);
	testLex("`hello \n world`",  [ Token(symbol!"Value",loc,Value("hello \n world")) ]);
	testLex("`hello \"world\"`", [ Token(symbol!"Value",loc,Value(`hello "world"` )) ]);

	// Double-Quote Strings
	testLex(`"hello world"`,         [ Token(symbol!"Value",loc,Value("hello world"   )) ]);
	testLex(`" hello world "`,       [ Token(symbol!"Value",loc,Value(" hello world " )) ]);
	testLex(`"hello \t world"`,      [ Token(symbol!"Value",loc,Value("hello \t world")) ]);
	testLex("\"hello \\\n world\"",  [ Token(symbol!"Value",loc,Value("hello \nworld" )) ]);

	// Characters
	testLex("'a'",  [ Token(symbol!"Value",loc,Value(cast(dchar) 'a')) ]);
	testLex("'\n'", [ Token(symbol!"Value",loc,Value(cast(dchar)'\n')) ]);
	
	// Unicode
	testLex("日本語",         [ Token(symbol!"Ident",loc,Value("日本語"))       ]);
	testLex("`おはよう、日本。`", [ Token(symbol!"Value",loc,Value(`おはよう、日本。`)) ]);
	testLex(`"おはよう、日本。"`, [ Token(symbol!"Value",loc,Value(`おはよう、日本。`)) ]);
	testLex("'月'",           [ Token(symbol!"Value",loc,Value("月"d.dup[0]))   ]);

	// Base64 Binary
	testLex("[aGVsbG8gd29ybGQ=]",              [ Token(symbol!"Value",loc,Value(cast(ubyte[])"hello world".dup))]);
	testLex("[ aGVsbG8gd29ybGQ= ]",            [ Token(symbol!"Value",loc,Value(cast(ubyte[])"hello world".dup))]);
	testLex("[\n aGVsbG8g \n \n d29ybGQ= \n]", [ Token(symbol!"Value",loc,Value(cast(ubyte[])"hello world".dup))]);

	// Date
	testLex( "1999/12/5", [ Token(symbol!"Value",loc,Value(Date( 1999, 12, 5))) ]);
	testLex( "2013/2/22", [ Token(symbol!"Value",loc,Value(Date( 2013, 2, 22))) ]);
	testLex("-2013/2/22", [ Token(symbol!"Value",loc,Value(Date(-2013, 2, 22))) ]);

	// DateTime, no timezone
	testLex( "2013/2/22 07:53",        [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime( 2013, 2, 22,  7, 53,  0)))) ]);
	testLex( "2013/2/22 \t 07:53",     [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime( 2013, 2, 22,  7, 53,  0)))) ]);
	testLex("-2013/2/22 07:53",        [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime(-2013, 2, 22,  7, 53,  0)))) ]);
	//testLex( "2013/2/22 -07:53",       [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime( 2013, 2, 22, -7, 53,  0)))) ]);
	//testLex("-2013/2/22 -07:53",       [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime(-2013, 2, 22, -7, 53,  0)))) ]);
	testLex( "2013/2/22 07:53:34",     [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime( 2013, 2, 22,  7, 53, 34)))) ]);
	testLex( "2013/2/22 07:53:34.123", [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime( 2013, 2, 22,  7, 53, 34), FracSec.from!"msecs"(123)))) ]);
	testLex( "2013/2/22 07:53.123",    [ Token(symbol!"Value",loc,Value(DateTimeFrac(DateTime( 2013, 2, 22,  7, 53,  0), FracSec.from!"msecs"(123)))) ]);

	// DateTime, with known timezone
	testLex( "2013/2/22 07:53-GMT+00:00",        [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53,  0), new SimpleTimeZone( hours(0)            )))) ]);
	testLex("-2013/2/22 07:53-GMT+00:00",        [ Token(symbol!"Value",loc,Value(SysTime(DateTime(-2013, 2, 22,  7, 53,  0), new SimpleTimeZone( hours(0)            )))) ]);
	//testLex( "2013/2/22 -07:53-GMT+00:00",       [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22, -7, 53,  0), new SimpleTimeZone( hours(0)            )))) ]);
	//testLex("-2013/2/22 -07:53-GMT+00:00",       [ Token(symbol!"Value",loc,Value(SysTime(DateTime(-2013, 2, 22, -7, 53,  0), new SimpleTimeZone( hours(0)            )))) ]);
	testLex( "2013/2/22 07:53-GMT+02:10",        [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53,  0), new SimpleTimeZone( hours(2)+minutes(10))))) ]);
	testLex( "2013/2/22 07:53-GMT-05:30",        [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53,  0), new SimpleTimeZone(-hours(5)-minutes(30))))) ]);
	testLex( "2013/2/22 07:53:34-GMT+00:00",     [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53, 34), new SimpleTimeZone( hours(0)            )))) ]);
	testLex( "2013/2/22 07:53:34-GMT+02:10",     [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53, 34), new SimpleTimeZone( hours(2)+minutes(10))))) ]);
	testLex( "2013/2/22 07:53:34-GMT-05:30",     [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53, 34), new SimpleTimeZone(-hours(5)-minutes(30))))) ]);
	testLex( "2013/2/22 07:53:34.123-GMT+00:00", [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53, 34), FracSec.from!"msecs"(123), new SimpleTimeZone( hours(0)            )))) ]);
	testLex( "2013/2/22 07:53:34.123-GMT+02:10", [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53, 34), FracSec.from!"msecs"(123), new SimpleTimeZone( hours(2)+minutes(10))))) ]);
	testLex( "2013/2/22 07:53:34.123-GMT-05:30", [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53, 34), FracSec.from!"msecs"(123), new SimpleTimeZone(-hours(5)-minutes(30))))) ]);
	testLex( "2013/2/22 07:53.123-GMT+00:00",    [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53,  0), FracSec.from!"msecs"(123), new SimpleTimeZone( hours(0)            )))) ]);
	testLex( "2013/2/22 07:53.123-GMT+02:10",    [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53,  0), FracSec.from!"msecs"(123), new SimpleTimeZone( hours(2)+minutes(10))))) ]);
	testLex( "2013/2/22 07:53.123-GMT-05:30",    [ Token(symbol!"Value",loc,Value(SysTime(DateTime( 2013, 2, 22,  7, 53,  0), FracSec.from!"msecs"(123), new SimpleTimeZone(-hours(5)-minutes(30))))) ]);

	// DateTime, with unknown timezone
	testLex( "2013/2/22 07:53-Bogus/Foo",        [ Token(symbol!"Value",loc,Value(DateTimeFracUnknownZone(DateTime( 2013, 2, 22,  7, 53,  0), FracSec.from!"msecs"(0), "Bogus/Foo")), "2013/2/22 07:53-Bogus/Foo") ]);
	testLex("-2013/2/22 07:53-Bogus/Foo",        [ Token(symbol!"Value",loc,Value(DateTimeFracUnknownZone(DateTime(-2013, 2, 22,  7, 53,  0), FracSec.from!"msecs"(0), "Bogus/Foo"))) ]);
	//testLex( "2013/2/22 -07:53-Bogus/Foo",       [ Token(symbol!"Value",loc,Value(DateTimeFracUnknownZone(DateTime( 2013, 2, 22, -7, 53,  0), FracSec.from!"msecs"(0), "Bogus/Foo"))) ]);
	//testLex("-2013/2/22 -07:53-Bogus/Foo",       [ Token(symbol!"Value",loc,Value(DateTimeFracUnknownZone(DateTime(-2013, 2, 22, -7, 53,  0), FracSec.from!"msecs"(0), "Bogus/Foo"))) ]);
	testLex( "2013/2/22 07:53:34-Bogus/Foo",     [ Token(symbol!"Value",loc,Value(DateTimeFracUnknownZone(DateTime( 2013, 2, 22,  7, 53, 34), FracSec.from!"msecs"(0), "Bogus/Foo"))) ]);
	testLex( "2013/2/22 07:53:34.123-Bogus/Foo", [ Token(symbol!"Value",loc,Value(DateTimeFracUnknownZone(DateTime( 2013, 2, 22,  7, 53, 34), FracSec.from!"msecs"(0), "Bogus/Foo"))) ]);
	testLex( "2013/2/22 07:53.123-Bogus/Foo",    [ Token(symbol!"Value",loc,Value(DateTimeFracUnknownZone(DateTime( 2013, 2, 22,  7, 53,  0), FracSec.from!"msecs"(0), "Bogus/Foo"))) ]);

	// Time Span
	testLex( "12:14:42",         [ Token(symbol!"Value",loc,Value( days( 0)+hours(12)+minutes(14)+seconds(42)+msecs(  0))) ]);
	testLex("-12:14:42",         [ Token(symbol!"Value",loc,Value(-days( 0)-hours(12)-minutes(14)-seconds(42)-msecs(  0))) ]);
	testLex( "00:09:12",         [ Token(symbol!"Value",loc,Value( days( 0)+hours( 0)+minutes( 9)+seconds(12)+msecs(  0))) ]);
	testLex( "00:00:01.023",     [ Token(symbol!"Value",loc,Value( days( 0)+hours( 0)+minutes( 0)+seconds( 1)+msecs( 23))) ]);
	testLex( "23d:05:21:23.532", [ Token(symbol!"Value",loc,Value( days(23)+hours( 5)+minutes(21)+seconds(23)+msecs(532))) ]);
	testLex("-23d:05:21:23.532", [ Token(symbol!"Value",loc,Value(-days(23)-hours( 5)-minutes(21)-seconds(23)-msecs(532))) ]);
	testLex( "23d:05:21:23",     [ Token(symbol!"Value",loc,Value( days(23)+hours( 5)+minutes(21)+seconds(23)+msecs(  0))) ]);

	// Combination
	testLex(`
		namespace:person "foo" "bar" 1 23L first="ひとみ" last="Smith" {
			namespace:age 37; namespace:favorite_color "blue" // comment
			somedate 2013/2/22  07:53 -- comment
			
			inventory /* comment */ {
				socks
			}
		}
	`,
	[
		Token(symbol!"EOL",loc,Value(null),"\n"),

		Token(symbol!"Ident", loc, Value(         null ), "namespace"),
		Token(symbol!":",     loc, Value(         null ), ":"),
		Token(symbol!"Ident", loc, Value(         null ), "person"),
		Token(symbol!"Value", loc, Value(        "foo" ), "foo"),
		Token(symbol!"Value", loc, Value(        "bar" ), "bar"),
		Token(symbol!"Value", loc, Value( cast( int) 1 ), "1"),
		Token(symbol!"Value", loc, Value( cast(long)23 ), "23L"),
		Token(symbol!"Ident", loc, Value(         null ), "first"),
		Token(symbol!"=",     loc, Value(         null ), "="),
		Token(symbol!"Value", loc, Value(       "ひとみ" ), "ひとみ"),
		Token(symbol!"Ident", loc, Value(         null ), "last"),
		Token(symbol!"=",     loc, Value(         null ), "="),
		Token(symbol!"Value", loc, Value(      "Smith" ), "Smith"),
		Token(symbol!"{",     loc, Value(         null ), "{"),
		Token(symbol!"EOL",   loc, Value(         null ), "\n"),

		Token(symbol!"Ident", loc, Value(        null ), "namespace"),
		Token(symbol!":",     loc, Value(        null ), ":"),
		Token(symbol!"Ident", loc, Value(        null ), "age"),
		Token(symbol!"Value", loc, Value( cast(int)37 ), "37"),
		Token(symbol!"EOL",   loc, Value(        null ), ";"),
		Token(symbol!"Ident", loc, Value(        null ), "namespace"),
		Token(symbol!":",     loc, Value(        null ), ":"),
		Token(symbol!"Ident", loc, Value(        null ), "favorite_color"),
		Token(symbol!"Value", loc, Value(      "blue" ), "blue"),
		Token(symbol!"EOL",   loc, Value(        null ), "\n"),

		Token(symbol!"Ident", loc, Value( null ), "somedate"),
		Token(symbol!"Value", loc, Value( DateTimeFrac(DateTime(2012, 2, 22, 7, 53, 0)) ), "2013/2/22  07:53"),
		Token(symbol!"EOL",   loc, Value( null ), "\n"),
		Token(symbol!"EOL",   loc, Value( null ), "\n"),


		Token(symbol!"Ident", loc, Value(null), "inventory"),
		Token(symbol!"{",     loc, Value(null), "{"),
		Token(symbol!"EOL",   loc, Value(null), "\n"),

		Token(symbol!"Ident", loc, Value(null), "socks"),
		Token(symbol!"EOL",   loc, Value(null), "\n"),

		Token(symbol!"}",     loc, Value(null), "}"),
		Token(symbol!"EOL",   loc, Value(null), "\n"),

		Token(symbol!"}",     loc, Value(null), "}"),
		Token(symbol!"EOL",   loc, Value(null), "\n"),
	]);
}
