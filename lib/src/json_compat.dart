/// Small decode bridge; keeps jsonDecode usage in one place.
library;

import 'dart:convert' as convert;

dynamic jsonDecodeCompat(String s) => convert.jsonDecode(s);
String jsonEncodeCompat(Object? o) => convert.jsonEncode(o);
