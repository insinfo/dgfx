// Offset n-rooks para 8, 16, 32 amostras
// Convertido de PolygonFiller.h

class SamplingPatterns {
  static const int shift8 = 3;
  static const int count8 = 8;
  static const List<double> offsets8 = [
    5.0 / 8.0,
    0.0 / 8.0,
    3.0 / 8.0,
    6.0 / 8.0,
    1.0 / 8.0,
    4.0 / 8.0,
    7.0 / 8.0,
    2.0 / 8.0
  ];

  static const int shift16 = 4;
  static const int count16 = 16;
  static const List<double> offsets16 = [
    1.0 / 16.0,
    8.0 / 16.0,
    4.0 / 16.0,
    15.0 / 16.0,
    11.0 / 16.0,
    2.0 / 16.0,
    6.0 / 16.0,
    14.0 / 16.0,
    10.0 / 16.0,
    3.0 / 16.0,
    7.0 / 16.0,
    12.0 / 16.0,
    0.0 / 16.0,
    9.0 / 16.0,
    5.0 / 16.0,
    13.0 / 16.0,
  ];

  static const int shift32 = 5;
  static const int count32 = 32;
  static const List<double> offsets32 = [
    28.0 / 32.0,
    13.0 / 32.0,
    6.0 / 32.0,
    23.0 / 32.0,
    0.0 / 32.0,
    17.0 / 32.0,
    10.0 / 32.0,
    27.0 / 32.0,
    4.0 / 32.0,
    21.0 / 32.0,
    14.0 / 32.0,
    31.0 / 32.0,
    8.0 / 32.0,
    25.0 / 32.0,
    18.0 / 32.0,
    3.0 / 32.0,
    12.0 / 32.0,
    29.0 / 32.0,
    22.0 / 32.0,
    7.0 / 32.0,
    16.0 / 32.0,
    1.0 / 32.0,
    26.0 / 32.0,
    11.0 / 32.0,
    20.0 / 32.0,
    5.0 / 32.0,
    30.0 / 32.0,
    15.0 / 32.0,
    24.0 / 32.0,
    9.0 / 32.0,
    2.0 / 32.0,
    19.0 / 32.0,
  ];
}
