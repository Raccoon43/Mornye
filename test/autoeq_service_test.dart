import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/autoeq_service.dart';

void main() {
  test('index lines parse with and without a rig', () {
    final entries = parseAutoEqIndex('''
# Index
- [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)) by HypetheSonics on GRAS RA0045
- [HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990
not an entry
''');
    expect(entries, hasLength(2));
    expect(entries[0].name, '1MORE Aero (ANC Off)');
    expect(
      entries[0].path,
      'HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)',
    );
    expect(entries[0].source, 'HypetheSonics on GRAS RA0045');
    expect(entries[1].source, 'oratory1990');
  });

  test('graphic curve samples onto 31 bands with headroom', () {
    final points = parseGraphicEq('GraphicEQ: 20 6.0; 1000 0.0; 20000 -4.0');
    expect(points.first, (20.0, 6.0));
    final manual = autoEqSettings(
      points,
      const EqualizerSettings(autoHeadroom: false, bass: 3),
    );
    expect(manual.gains, hasLength(31));
    expect(manual.gains.first, closeTo(6, 1e-9));
    expect(manual.gains[17], closeTo(0, 1e-9)); // 1000 Hz
    expect(manual.gains.last, closeTo(-4, 1e-9));
    expect(manual.preamp, -6);
    expect(manual.bass, 0);
    // Auto headroom already removes the peak, so no preamp cut on top.
    expect(autoEqSettings(points, const EqualizerSettings()).preamp, 0);
  });

  test('a page without GraphicEQ is rejected', () {
    expect(() => parseGraphicEq('<html>404</html>'), throwsFormatException);
  });
}
