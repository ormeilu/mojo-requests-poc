# Minimal JSON parser — pure Mojo.
#
# Mojo 1.0 has no std.json, so we ship a small recursive-descent parser producing a JSONValue.
# Supports the full JSON grammar: objects, arrays, strings (with escapes), numbers, true/false/null.
#
# NOTE: because JSONValue is recursive (objects/arrays contain JSONValues), the collection fields are
# heap-allocated behind OwnedPointer so the struct has a fixed, deletable layout.

from .exceptions import request_exception
from std.memory import OwnedPointer


struct JSONValue(Movable, Copyable, Writable):
    """A node in a parsed JSON document.

    ``kind`` is one of: "object", "array", "string", "int", "float", "bool", "null".
    Containers are heap-allocated behind OwnedPointer so the recursive type has a fixed layout. Copyable via deep copy.
    """
    var kind: String
    var _str: String
    var _int: Int
    var _float: Float64
    var _bool: Bool
    var _object: OwnedPointer[Dict[String, JSONValue]]
    var _array: OwnedPointer[List[JSONValue]]

    def __init__(out self):
        self.kind = "null"
        self._str = ""
        self._int = 0
        self._float = 0.0
        self._bool = False
        var d: Dict[String, JSONValue] = {}
        var a: List[JSONValue] = []
        self._object = OwnedPointer[Dict[String, JSONValue]](d^)
        self._array = OwnedPointer[List[JSONValue]](a^)

    def __init__(out self, kind: String):
        self.kind = kind
        self._str = ""
        self._int = 0
        self._float = 0.0
        self._bool = False
        var d: Dict[String, JSONValue] = {}
        var a: List[JSONValue] = []
        self._object = OwnedPointer[Dict[String, JSONValue]](d^)
        self._array = OwnedPointer[List[JSONValue]](a^)

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self._str = copy._str
        self._int = copy._int
        self._float = copy._float
        self._bool = copy._bool
        var d: Dict[String, JSONValue] = {}
        for entry in copy._object[].items():
            d[entry.key] = entry.value.copy()
        var a: List[JSONValue] = []
        for item in copy._array[]:
            a.append(item.copy())
        self._object = OwnedPointer[Dict[String, JSONValue]](d^)
        self._array = OwnedPointer[List[JSONValue]](a^)

    def as_string(self) raises -> String:
        if self.kind != "string":
            raise request_exception(String(t"JSON value is not a string (was {self.kind})"))
        return self._str

    def as_int(self) raises -> Int:
        if self.kind != "int":
            raise request_exception(String(t"JSON value is not an int (was {self.kind})"))
        return self._int

    def as_float(self) raises -> Float64:
        if self.kind != "float" and self.kind != "int":
            raise request_exception(String(t"JSON value is not a float (was {self.kind})"))
        if self.kind == "int":
            return Float64(self._int)
        return self._float

    def as_bool(self) raises -> Bool:
        if self.kind != "bool":
            raise request_exception(String(t"JSON value is not a bool (was {self.kind})"))
        return self._bool

    def __getitem__(self, key: String) raises -> JSONValue:
        if self.kind != "object":
            raise request_exception(String(t"JSON value is not an object (was {self.kind})"))
        return self._object[][key].copy()

    def get(self, key: String, default: JSONValue) raises -> JSONValue:
        if self.kind != "object":
            return default
        if not self._object[].contains(key):
            return default
        return self._object[][key].copy()

    def __getitem__(self, index: Int) raises -> JSONValue:
        if self.kind != "array":
            raise request_exception(String(t"JSON value is not an array (was {self.kind})"))
        if index < 0 or index >= len(self._array[]):
            raise request_exception(String(t"JSON array index out of range: {index}"))
        return self._array[][index].copy()

    def len(self) -> Int:
        if self.kind == "array":
            return len(self._array[])
        if self.kind == "object":
            return len(self._object[])
        return 0

    def is_null(self) -> Bool:
        return self.kind == "null"

    def write_to(self, mut writer: Some[Writer]):
        if self.kind == "string":
            writer.write("\"", self._str, "\"")
        elif self.kind == "int":
            writer.write(self._int)
        elif self.kind == "float":
            writer.write(self._float)
        elif self.kind == "bool":
            writer.write(self._bool)
        elif self.kind == "null":
            writer.write("null")
        elif self.kind == "array":
            writer.write("[...array...")
        elif self.kind == "object":
            writer.write("{...object...")
        else:
            writer.write("?")


def parse_json(s: String) raises -> JSONValue:
    """Parse a JSON document string into a JSONValue. Raises request_exception on malformed input."""
    var p = _Parser(s)
    p.skip_ws()
    var v = p.parse_value()
    p.skip_ws()
    if p.pos != p.n:
        raise request_exception("trailing data after JSON value")
    return v^


@fieldwise_init
struct _Parser:
    var src: String
    var pos: Int
    var n: Int

    def __init__(out self, src: String):
        self.src = src
        self.pos = 0
        self.n = src.byte_length()

    def skip_ws(mut self):
        while self.pos < self.n:
            var b = self.src.unsafe_ptr()[self.pos]
            if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D:
                self.pos += 1
            else:
                break

    def peek(self) -> UInt8:
        if self.pos >= self.n:
            return 0
        return self.src.unsafe_ptr()[self.pos]

    def parse_value(mut self) raises -> JSONValue:
        self.skip_ws()
        if self.pos >= self.n:
            raise request_exception("unexpected end of JSON input")
        var b = self.peek()
        if b == 0x7B:  # '{'
            return self._parse_object()
        if b == 0x5B:  # '['
            return self._parse_array()
        if b == 0x22:  # '"'
            var s = self._parse_string()
            var v = JSONValue("string")
            v._str = s
            return v^
        if b == 0x74 or b == 0x66:  # 't' or 'f'
            return self._parse_literal()
        if b == 0x6E or b == 0x2D:  # 'n' or '-'
            return self._parse_number_or_null()
        if (b >= 0x30 and b <= 0x39) or b == 0x2B:  # digit or '+'
            return self._parse_number_or_null()
        raise request_exception(String(t"unexpected character in JSON: {Codepoint(unsafe_unchecked_codepoint=UInt32(b))}"))

    def _parse_object(mut self) raises -> JSONValue:
        self.pos += 1  # consume '{'
        self.skip_ws()
        var v = JSONValue("object")
        if self.peek() == 0x7D:  # '}'
            self.pos += 1
            return v^
        while True:
            self.skip_ws()
            if self.peek() != 0x22:  # '"'
                raise request_exception("expected string key in JSON object")
            var key = self._parse_string()
            self.skip_ws()
            if self.peek() != 0x3A:  # ':'
                raise request_exception("expected ':' after key in JSON object")
            self.pos += 1
            var val = self.parse_value()
            v._object[][key] = val^
            self.skip_ws()
            var b = self.peek()
            if b == 0x7D:  # '}'
                self.pos += 1
                break
            if b != 0x2C:  # ','
                raise request_exception("expected ',' or '}' in JSON object")
            self.pos += 1
        return v^

    def _parse_array(mut self) raises -> JSONValue:
        self.pos += 1  # consume '['
        self.skip_ws()
        var v = JSONValue("array")
        if self.peek() == 0x5D:  # ']'
            self.pos += 1
            return v^
        while True:
            var val = self.parse_value()
            v._array[].append(val^)
            self.skip_ws()
            var b = self.peek()
            if b == 0x5D:  # ']'
                self.pos += 1
                break
            if b != 0x2C:  # ','
                raise request_exception("expected ',' or ']' in JSON array")
            self.pos += 1
        return v^

    def _parse_string(mut self) raises -> String:
        self.pos += 1  # consume opening '"'
        var out = String()
        var sp = self.src.unsafe_ptr()
        while self.pos < self.n:
            var b = sp[self.pos]
            if b == 0x22:  # closing '"'
                self.pos += 1
                return out
            if b == 0x5C:  # backslash
                self.pos += 1
                if self.pos >= self.n:
                    raise request_exception("unterminated escape in JSON string")
                var e = sp[self.pos]
                self.pos += 1
                if e == 0x22:
                    out += "\""
                elif e == 0x5C:
                    out += "\\"
                elif e == 0x2F:
                    out += "/"
                elif e == 0x62:  # 'b'
                    out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(0x08)))
                elif e == 0x66:  # 'f'
                    out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(0x0C)))
                elif e == 0x72:  # 'r'
                    out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(0x0D)))
                elif e == 0x6E:  # 'n'
                    out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(0x0A)))
                elif e == 0x74:  # 't' — tab
                    out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(0x09)))
                elif e == 0x75:  # 'u' — unicode escape \uXXXX
                    if self.pos + 4 > self.n:
                        raise request_exception("bad \\uXXXX escape")
                    var hex = String(self.src[byte=self.pos : self.pos + 4])
                    self.pos += 4
                    var cp = _parse_hex4(hex)
                    if cp == None:
                        raise request_exception(String(t"bad \\u escape: {hex}"))
                    out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(cp.value())))
                else:
                    raise request_exception("invalid escape in JSON string")
            else:
                out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(b)))
                self.pos += 1
        raise request_exception("unterminated JSON string")

    def _parse_literal(mut self) raises -> JSONValue:
        var sp = self.src.unsafe_ptr()
        if self.pos + 4 <= self.n and sp[self.pos] == 0x74 and sp[self.pos + 1] == 0x72 and sp[self.pos + 2] == 0x75 and sp[self.pos + 3] == 0x65:
            # "true"
            self.pos += 4
            var v = JSONValue("bool")
            v._bool = True
            return v^
        if self.pos + 5 <= self.n and sp[self.pos] == 0x66 and sp[self.pos + 1] == 0x61 and sp[self.pos + 2] == 0x6C and sp[self.pos + 3] == 0x73 and sp[self.pos + 4] == 0x65:
            # "false"
            self.pos += 5
            var v = JSONValue("bool")
            v._bool = False
            return v^
        raise request_exception("invalid JSON literal (expected true/false)")

    def _parse_number_or_null(mut self) raises -> JSONValue:
        var sp = self.src.unsafe_ptr()
        # "null"
        if sp[self.pos] == 0x6E:  # 'n'
            if self.pos + 4 <= self.n and sp[self.pos + 1] == 0x75 and sp[self.pos + 2] == 0x6C and sp[self.pos + 3] == 0x6C:
                self.pos += 4
                return JSONValue("null")
            raise request_exception("invalid JSON literal (expected null)")
        # number
        var start = self.pos
        var is_float = False
        if sp[self.pos] == 0x2D or sp[self.pos] == 0x2B:  # leading - or +
            self.pos += 1
        while self.pos < self.n:
            var b = sp[self.pos]
            if (b >= 0x30 and b <= 0x39):
                self.pos += 1
            elif b == 0x2E:  # '.'
                is_float = True
                self.pos += 1
            elif b == 0x65 or b == 0x45:  # 'e' or 'E'
                is_float = True
                self.pos += 1
            elif b == 0x2D or b == 0x2B:  # '-' or '+' in exponent
                self.pos += 1
            else:
                break
        var num_str = String(self.src[byte=start : self.pos])
        if is_float:
            var v = JSONValue("float")
            v._float = _parse_float(num_str)
            return v^
        var v = JSONValue("int")
        v._int = _parse_int_strict(num_str)
        return v^


def _parse_hex4(s: String) -> Optional[Int]:
    if s.byte_length() != 4:
        return None
    var sp = s.unsafe_ptr()
    var v = 0
    for i in range(4):
        var d = _hex_digit_local(sp[i])
        if d < 0:
            return None
        v = v * 16 + d
    return v


def _hex_digit_local(b: UInt8) -> Int:
    if b >= 0x30 and b <= 0x39:
        return Int(b - 0x30)
    if b >= 0x41 and b <= 0x46:
        return Int(b - 0x41 + 10)
    if b >= 0x61 and b <= 0x66:
        return Int(b - 0x61 + 10)
    return -1


def _parse_float(s: String) -> Float64:
    """Parse a JSON number string (possibly with exponent) to Float64."""
    var sp = s.unsafe_ptr()
    var n = s.byte_length()
    var i = 0
    var neg = False
    if i < n and sp[i] == 0x2D:
        neg = True
        i += 1
    elif i < n and sp[i] == 0x2B:
        i += 1
    var int_part = 0.0
    while i < n and sp[i] >= 0x30 and sp[i] <= 0x39:
        int_part = int_part * 10.0 + Float64(sp[i]) - 48.0
        i += 1
    if i < n and sp[i] == 0x2E:
        i += 1
        var frac = 0.1
        while i < n and sp[i] >= 0x30 and sp[i] <= 0x39:
            int_part += (Float64(sp[i]) - 48.0) * frac
            frac *= 0.1
            i += 1
    if i < n and (sp[i] == 0x65 or sp[i] == 0x45):
        i += 1
        var exp_neg = False
        if i < n and sp[i] == 0x2D:
            exp_neg = True
            i += 1
        elif i < n and sp[i] == 0x2B:
            i += 1
        var exp = 0
        while i < n and sp[i] >= 0x30 and sp[i] <= 0x39:
            exp = exp * 10 + Int(sp[i]) - 0x30
            i += 1
        var mul = 1.0
        var e = exp
        while e > 0:
            mul *= 10.0
            e -= 1
        if exp_neg:
            int_part /= mul
        else:
            int_part *= mul
    var result = int_part
    if neg:
        result = -result
    return result


def _parse_int_strict(s: String) -> Int:
    """Parse a digit string (possibly signed) to Int."""
    var sp = s.unsafe_ptr()
    var n = s.byte_length()
    var i = 0
    var neg = False
    if i < n and sp[i] == 0x2D:
        neg = True
        i += 1
    elif i < n and sp[i] == 0x2B:
        i += 1
    var v = 0
    while i < n and sp[i] >= 0x30 and sp[i] <= 0x39:
        v = v * 10 + Int(sp[i]) - 0x30
        i += 1
    if neg:
        return -v
    return v
