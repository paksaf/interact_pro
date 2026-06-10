import 'package:flutter/material.dart' show Icons, IconData;

/// One convertible unit within a [ConversionCategory].
///
/// `ratioToBase` is what you multiply a value in this unit by to get the
/// equivalent value in the category's *base* unit (the first unit in
/// each category's list). This works for every category EXCEPT
/// temperature, which uses additive offsets and is special-cased in
/// [convert] below.
class Unit {
  const Unit({
    required this.name,
    required this.symbol,
    required this.ratioToBase,
  });
  final String name;
  final String symbol;
  final double ratioToBase;
}

/// A group of related units that convert into each other.
class ConversionCategory {
  const ConversionCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.units,
  });
  final String id;
  final String name;
  final IconData icon;
  final List<Unit> units;
}

/// Convert [value] from [from] to [to] within [category]. Handles
/// temperature's additive C/F/K conversions specially; everything else
/// is a pure ratio chain through the base unit.
double convert({
  required double value,
  required Unit from,
  required Unit to,
  required ConversionCategory category,
}) {
  if (from == to) return value;

  if (category.id == 'temperature') {
    // Step 1 — normalise to Celsius (the implicit base for temperature).
    final celsius = switch (from.symbol) {
      '°C' => value,
      '°F' => (value - 32) * 5.0 / 9.0,
      'K' => value - 273.15,
      _ => value,
    };
    // Step 2 — convert Celsius to the target unit.
    return switch (to.symbol) {
      '°C' => celsius,
      '°F' => celsius * 9.0 / 5.0 + 32,
      'K' => celsius + 273.15,
      _ => celsius,
    };
  }

  // Generic ratio path: convert to base, then base to target.
  final inBase = value * from.ratioToBase;
  return inBase / to.ratioToBase;
}

/// Catalogue of every category we support. Order shown to users matches
/// list order.
class Converters {
  Converters._();

  static const List<ConversionCategory> all = [
    ConversionCategory(
      id: 'length',
      name: 'Length',
      icon: Icons.straighten,
      units: [
        Unit(name: 'Metre', symbol: 'm', ratioToBase: 1),
        Unit(name: 'Kilometre', symbol: 'km', ratioToBase: 1000),
        Unit(name: 'Centimetre', symbol: 'cm', ratioToBase: 0.01),
        Unit(name: 'Millimetre', symbol: 'mm', ratioToBase: 0.001),
        Unit(name: 'Inch', symbol: 'in', ratioToBase: 0.0254),
        Unit(name: 'Foot', symbol: 'ft', ratioToBase: 0.3048),
        Unit(name: 'Yard', symbol: 'yd', ratioToBase: 0.9144),
        Unit(name: 'Mile', symbol: 'mi', ratioToBase: 1609.344),
        Unit(name: 'Nautical mile', symbol: 'nmi', ratioToBase: 1852),
      ],
    ),
    ConversionCategory(
      id: 'area',
      name: 'Area',
      icon: Icons.crop_din,
      units: [
        Unit(name: 'Square metre', symbol: 'm²', ratioToBase: 1),
        Unit(name: 'Square kilometre', symbol: 'km²', ratioToBase: 1e6),
        Unit(name: 'Square centimetre', symbol: 'cm²', ratioToBase: 0.0001),
        Unit(name: 'Square mile', symbol: 'mi²', ratioToBase: 2589988.110336),
        Unit(name: 'Square foot', symbol: 'ft²', ratioToBase: 0.09290304),
        Unit(name: 'Square inch', symbol: 'in²', ratioToBase: 0.00064516),
        Unit(name: 'Acre', symbol: 'ac', ratioToBase: 4046.8564224),
        Unit(name: 'Hectare', symbol: 'ha', ratioToBase: 10000),
      ],
    ),
    ConversionCategory(
      id: 'volume',
      name: 'Volume',
      icon: Icons.local_drink_outlined,
      units: [
        Unit(name: 'Litre', symbol: 'L', ratioToBase: 1),
        Unit(name: 'Millilitre', symbol: 'mL', ratioToBase: 0.001),
        Unit(name: 'Cubic metre', symbol: 'm³', ratioToBase: 1000),
        Unit(name: 'Gallon (US)', symbol: 'gal', ratioToBase: 3.785411784),
        Unit(name: 'Gallon (UK)', symbol: 'gal UK', ratioToBase: 4.54609),
        Unit(name: 'Quart (US)', symbol: 'qt', ratioToBase: 0.946352946),
        Unit(name: 'Pint (US)', symbol: 'pt', ratioToBase: 0.473176473),
        Unit(name: 'Cup (US)', symbol: 'cup', ratioToBase: 0.2365882365),
        Unit(name: 'Fluid ounce (US)', symbol: 'fl oz', ratioToBase: 0.0295735296),
        Unit(name: 'Tablespoon', symbol: 'tbsp', ratioToBase: 0.01478676478125),
        Unit(name: 'Teaspoon', symbol: 'tsp', ratioToBase: 0.00492892159375),
      ],
    ),
    ConversionCategory(
      id: 'weight',
      name: 'Weight',
      icon: Icons.fitness_center,
      units: [
        Unit(name: 'Kilogram', symbol: 'kg', ratioToBase: 1),
        Unit(name: 'Gram', symbol: 'g', ratioToBase: 0.001),
        Unit(name: 'Milligram', symbol: 'mg', ratioToBase: 1e-6),
        Unit(name: 'Pound', symbol: 'lb', ratioToBase: 0.45359237),
        Unit(name: 'Ounce', symbol: 'oz', ratioToBase: 0.028349523125),
        Unit(name: 'Stone', symbol: 'st', ratioToBase: 6.35029318),
        Unit(name: 'Metric ton', symbol: 't', ratioToBase: 1000),
        Unit(name: 'US ton', symbol: 'ton US', ratioToBase: 907.18474),
      ],
    ),
    ConversionCategory(
      id: 'temperature',
      name: 'Temperature',
      icon: Icons.thermostat,
      units: [
        // Special-cased in convert() — ratioToBase is unused for temp.
        Unit(name: 'Celsius', symbol: '°C', ratioToBase: 1),
        Unit(name: 'Fahrenheit', symbol: '°F', ratioToBase: 1),
        Unit(name: 'Kelvin', symbol: 'K', ratioToBase: 1),
      ],
    ),
    ConversionCategory(
      id: 'time',
      name: 'Time',
      icon: Icons.schedule,
      units: [
        Unit(name: 'Second', symbol: 's', ratioToBase: 1),
        Unit(name: 'Millisecond', symbol: 'ms', ratioToBase: 0.001),
        Unit(name: 'Minute', symbol: 'min', ratioToBase: 60),
        Unit(name: 'Hour', symbol: 'h', ratioToBase: 3600),
        Unit(name: 'Day', symbol: 'd', ratioToBase: 86400),
        Unit(name: 'Week', symbol: 'wk', ratioToBase: 604800),
        Unit(name: 'Month (30d)', symbol: 'mo', ratioToBase: 2592000),
        Unit(name: 'Year (365d)', symbol: 'yr', ratioToBase: 31536000),
      ],
    ),
    ConversionCategory(
      id: 'data',
      name: 'Data',
      icon: Icons.storage,
      units: [
        // SI (decimal): 1 KB = 1000 B
        Unit(name: 'Byte', symbol: 'B', ratioToBase: 1),
        Unit(name: 'Kilobyte', symbol: 'KB', ratioToBase: 1e3),
        Unit(name: 'Megabyte', symbol: 'MB', ratioToBase: 1e6),
        Unit(name: 'Gigabyte', symbol: 'GB', ratioToBase: 1e9),
        Unit(name: 'Terabyte', symbol: 'TB', ratioToBase: 1e12),
        // IEC (binary): 1 KiB = 1024 B
        Unit(name: 'Kibibyte', symbol: 'KiB', ratioToBase: 1024),
        Unit(name: 'Mebibyte', symbol: 'MiB', ratioToBase: 1048576),
        Unit(name: 'Gibibyte', symbol: 'GiB', ratioToBase: 1073741824),
        Unit(name: 'Tebibyte', symbol: 'TiB', ratioToBase: 1099511627776),
      ],
    ),
    ConversionCategory(
      id: 'speed',
      name: 'Speed',
      icon: Icons.speed,
      units: [
        Unit(name: 'Metre / second', symbol: 'm/s', ratioToBase: 1),
        Unit(name: 'Kilometre / hour', symbol: 'km/h', ratioToBase: 0.2777777778),
        Unit(name: 'Mile / hour', symbol: 'mph', ratioToBase: 0.44704),
        Unit(name: 'Foot / second', symbol: 'ft/s', ratioToBase: 0.3048),
        Unit(name: 'Knot', symbol: 'kn', ratioToBase: 0.5144444444),
      ],
    ),
    ConversionCategory(
      id: 'pressure',
      name: 'Pressure',
      icon: Icons.compress,
      units: [
        Unit(name: 'Pascal', symbol: 'Pa', ratioToBase: 1),
        Unit(name: 'Kilopascal', symbol: 'kPa', ratioToBase: 1000),
        Unit(name: 'Megapascal', symbol: 'MPa', ratioToBase: 1e6),
        Unit(name: 'Bar', symbol: 'bar', ratioToBase: 100000),
        Unit(name: 'Atmosphere', symbol: 'atm', ratioToBase: 101325),
        Unit(name: 'PSI', symbol: 'psi', ratioToBase: 6894.757293168),
        Unit(name: 'mmHg / Torr', symbol: 'mmHg', ratioToBase: 133.322387415),
      ],
    ),
  ];

  static ConversionCategory byId(String id) =>
      all.firstWhere((c) => c.id == id, orElse: () => all.first);
}
