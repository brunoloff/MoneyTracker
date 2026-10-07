import 'dart:convert';
import 'package:crypto/crypto.dart';

String hashText(String value, [int? length]) {
  final hex = sha256.convert(utf8.encode(value)).toString();
  return length == null ? hex : hex.substring(0, length);
}

String? digest(List<int>? value) =>
    value == null ? null : sha256.convert(value).toString();
dynamic clone(dynamic value) => jsonDecode(jsonEncode(value));
List<Map<String, dynamic>> maps(dynamic value) =>
    (value as List).map((v) => Map<String, dynamic>.from(v as Map)).toList();
bool enabled(Map r) => r['enabled'] != false;
bool present(dynamic value) =>
    value != null &&
    value != '' &&
    value != false &&
    value != 0 &&
    !(value is Iterable && value.isEmpty) &&
    !(value is Map && value.isEmpty);
String pythonString(dynamic value) {
  if (value == null) return 'None';
  if (value == true) return 'True';
  if (value == false) return 'False';
  if (value is Map) {
    return '{${value.entries.map((e) => '${pythonRepr(e.key)}: ${pythonRepr(e.value)}').join(', ')}}';
  }
  if (value is List) return '[${value.map(pythonRepr).join(', ')}]';
  return value.toString();
}

String pythonRepr(dynamic v) => v is String
    ? "'${v.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t')}'"
    : pythonString(v);
int unicodeCompare(String a, String b) {
  final x = a.runes.toList(), y = b.runes.toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return x.length.compareTo(y.length);
}

/// Python json.dumps compatibility is part of the legacy ID format.
String pythonJson(
  dynamic value, {
  bool sorted = false,
  bool compact = false,
  bool ascii = true,
}) {
  String encode(dynamic v) {
    if (v is String) {
      final s = jsonEncode(v);
      if (!ascii) return s;
      return String.fromCharCodes(
        s.codeUnits.expand(
          (c) => c > 127
              ? '\\u${c.toRadixString(16).padLeft(4, '0')}'.codeUnits
              : [c],
        ),
      );
    }
    if (v is Map) {
      final keys = v.keys.cast<String>().toList();
      if (sorted) keys.sort(unicodeCompare);
      return '{${keys.map((k) => '${encode(k)}:${compact ? '' : ' '}${encode(v[k])}').join(compact ? ',' : ', ')}}';
    }
    if (v is List) return '[${v.map(encode).join(compact ? ',' : ', ')}]';
    if (v is double &&
        v.isFinite &&
        v != 0 &&
        (v.abs() < 0.0001 || v.abs() >= 1e16)) {
      final parts = v.toStringAsExponential().split('e');
      final exponent = int.parse(parts[1]);
      return '${parts[0]}e${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
    }
    return jsonEncode(v);
  }

  return encode(value);
}

/// Exact rational arithmetic; rounding bank cents uses half-to-even.
class Exact implements Comparable<Exact> {
  final BigInt numerator, denominator;
  Exact(this.numerator, [BigInt? denominator])
    : denominator = denominator ?? BigInt.one {
    if (this.denominator <= BigInt.zero) {
      throw const FormatException('Invalid decimal denominator');
    }
  }
  factory Exact.parse(dynamic value) {
    final match = RegExp(
      r'^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
    ).firstMatch(value.toString());
    if (match == null) throw const FormatException('Invalid decimal amount');
    final fraction = match[3] ?? '';
    var n = BigInt.parse('${match[2]}$fraction');
    if (match[1] == '-') n = -n;
    final scale = fraction.length - int.parse(match[4] ?? '0');
    if (scale.abs() > 1000) {
      throw const FormatException('Decimal amount is too large');
    }
    return scale >= 0
        ? Exact(n, BigInt.from(10).pow(scale))
        : Exact(n * BigInt.from(10).pow(-scale));
  }
  Exact operator +(Exact b) => Exact(
    numerator * b.denominator + b.numerator * denominator,
    denominator * b.denominator,
  );
  Exact operator -(Exact b) => Exact(
    numerator * b.denominator - b.numerator * denominator,
    denominator * b.denominator,
  );
  Exact operator *(Exact b) =>
      Exact(numerator * b.numerator, denominator * b.denominator);
  Exact operator /(Exact b) {
    if (b.numerator == BigInt.zero) {
      throw const FormatException('Zero exchange rate');
    }
    return Exact(
      numerator *
          b.denominator *
          (b.numerator.isNegative ? -BigInt.one : BigInt.one),
      denominator * b.numerator.abs(),
    );
  }

  Exact get abs => Exact(numerator.abs(), denominator);
  static int _integer(BigInt value) {
    final maximum = (BigInt.one << 63) - BigInt.one;
    if (value.abs() > maximum) {
      throw const FormatException('Amount exceeds the supported integer range');
    }
    return value.toInt();
  }

  int truncate() => _integer(numerator ~/ denominator);
  int roundEven() {
    final a = numerator.abs(),
        q = a ~/ denominator,
        rem = a.remainder(denominator) * BigInt.two;
    final rounded =
        q +
        (rem > denominator || rem == denominator && q.isOdd
            ? BigInt.one
            : BigInt.zero);
    return _integer(numerator.isNegative ? -rounded : rounded);
  }

  double toDouble() => numerator.toDouble() / denominator.toDouble();
  @override
  int compareTo(Exact other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);
}

int cents(dynamic value, {bool round = false}) {
  final amount = Exact.parse(value) * Exact(BigInt.from(100));
  return round ? amount.roundEven() : amount.truncate();
}

String day(DateTime date) => date.toIso8601String().substring(0, 10);
DateTime dateOnly(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('Choose a valid date');
  }
  final d = DateTime.parse('${value}T00:00:00Z');
  if (day(d) != value) throw const FormatException('Choose a valid date');
  return d;
}
