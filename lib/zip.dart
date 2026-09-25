// The home ZIP lookup (DESIGN.md section 9): first run, the phone has
// internet (that is how the app got installed), so the ZIP's center is
// looked up ONLINE and saved as hard data. No bundled ZIP table (the
// invented flow Brett rejected stays rejected); a failed lookup is an
// honest error the user sees, never a guess.

import 'dart:convert';
import 'dart:io';

class ZipLookupException implements Exception {
  final String message;
  ZipLookupException(this.message);
  @override
  String toString() => message;
}

/// The center of a US ZIP code: (lat, lon). Uses the free, keyless
/// zippopotam.us service.
Future<(double, double)> lookupZip(String zip) async {
  final clean = zip.trim();
  if (!RegExp(r'^\d{5}$').hasMatch(clean)) {
    throw ZipLookupException('a ZIP code is 5 digits');
  }
  final Uri uri;
  try {
    uri = Uri.parse('https://api.zippopotam.us/us/$clean');
  } catch (_) {
    throw ZipLookupException('bad ZIP request');
  }
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    final req = await client.getUrl(uri);
    final res = await req.close();
    if (res.statusCode != 200) {
      client.close();
      throw ZipLookupException(
          'ZIP $clean not found (service said ${res.statusCode})');
    }
    final body = jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, Object?>;
    client.close();
    final places = body['places'];
    if (places is! List || places.isEmpty) {
      throw ZipLookupException('ZIP $clean has no location data');
    }
    final place = places.first as Map<String, Object?>;
    return (
      double.parse(place['latitude'] as String),
      double.parse(place['longitude'] as String),
    );
  } on ZipLookupException {
    rethrow;
  } catch (err) {
    throw ZipLookupException('ZIP lookup failed (no internet?): $err');
  }
}
