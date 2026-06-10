import 'package:flutter/material.dart';

/// Material 3 theme — golden + green brand palette.
///
/// Material 3's `ColorScheme` is normally generated from a single seed
/// colour, but for a two-colour brand we override the key roles directly
/// so neither role gets washed out by the M3 tonal-palette generation.
///
/// Roles:
///   • primary   — golden (action buttons, FABs, key accents)
///   • secondary — green  (counterpoint accents, NavigationBar indicator,
///                          stamp / badge highlights)
///   • tertiary  — desaturated green-gold blend, used sparingly for
///                  per-feature theming (chips, info toasts).
///
/// To rebrand: change `_primary` and `_secondary` and rebuild — every
/// screen picks up the new colours via `Theme.of(context).colorScheme`.
class AppTheme {
  AppTheme._();

  // Brand colours.
  static const Color _primary = Color(0xFFC9A227);   // Golden
  static const Color _secondary = Color(0xFF1B7A3E); // Green
  static const Color _tertiary = Color(0xFF8B7A1F);  // Olive blend

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  /// TV-optimized theme overlay. Same brand colors, but every focusable
  /// widget gets a thick, high-contrast yellow ring on D-pad focus so
  /// the user can see what's selected from across the room (10ft viewing
  /// distance vs the 18-inch phone distance Material 3 defaults assume).
  ///
  /// Used by `app.dart` when `DeviceInfo.isAndroidTv` is true. The
  /// brand palette stays identical — only focus / overlay behaviour
  /// changes — so screens still look like Pro, just with more visible
  /// keyboard / remote navigation affordances.
  static ThemeData lightTv() => _buildTv(Brightness.light);
  static ThemeData darkTv() => _buildTv(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: _primary,
      brightness: brightness,
    );
    // Override the seed-generated values for the three brand roles.
    // M3's tonal-palette generation interpolates between primary and
    // surface, so explicitly setting the on-* pairs keeps WCAG contrast
    // ≥ 4.5:1 against the foregrounds we draw (white text on golden,
    // white text on green).
    final scheme = base.copyWith(
      primary: _primary,
      onPrimary: brightness == Brightness.light
          ? const Color(0xFF1A1300)
          : const Color(0xFFFFF8E1),
      secondary: _secondary,
      onSecondary: const Color(0xFFFFFFFF),
      tertiary: _tertiary,
      onTertiary: const Color(0xFFFFFFFF),
      // Containers: lighter / darker tints used for chip backgrounds and
      // similar.
      primaryContainer: brightness == Brightness.light
          ? const Color(0xFFFFE69A)
          : const Color(0xFF6E5300),
      onPrimaryContainer: brightness == Brightness.light
          ? const Color(0xFF231900)
          : const Color(0xFFFFF1B5),
      secondaryContainer: brightness == Brightness.light
          ? const Color(0xFFC7EBD0)
          : const Color(0xFF115A2A),
      onSecondaryContainer: brightness == Brightness.light
          ? const Color(0xFF002111)
          : const Color(0xFFD7F2DC),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        // Green-tinted indicator behind the selected nav destination
        // matches the brand's secondary role and contrasts well with
        // the golden primary used elsewhere.
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          );
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      // Floating action buttons land on green (secondary) so they read
      // as "do this thing" without competing with the golden primary
      // used on most page-level CTAs.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.secondary,
        foregroundColor: scheme.onSecondary,
      ),
      // Tab indicators (used by Scanner / Saved-codes / Stamp picker) —
      // golden underline.
      tabBarTheme: TabBarThemeData(
        indicatorColor: scheme.primary,
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
      ),
    );
  }

  /// Brand colours exposed for places that need the literal hex (splash
  /// screen, Caddy log icons, anywhere we can't reach Theme.of(context)).
  static const Color brandGold = _primary;
  static const Color brandGreen = _secondary;
  static const Color brandSurfaceDark = Color(0xFF0A2A1F); // dark green for splash bg

  /// High-contrast yellow used for TV D-pad focus halos. Picked to be
  /// visible against BOTH the light parchment surfaces (book shelves)
  /// AND the dark navy ones (viewer toolbar). Material yellow 500 hits
  /// ~AAA contrast on dark backgrounds and ~AA on light.
  static const Color _tvFocusColor = Color(0xFFFFEB3B);
  static const double _tvFocusBorderWidth = 3.0;

  static ThemeData _buildTv(Brightness brightness) {
    // Start from the regular brand theme so colours / button shapes /
    // font sizes stay identical. We only override the focus-related
    // widget-state properties so D-pad navigation reads from 10ft.
    final base = _build(brightness);
    final tvFocusFill = _tvFocusColor.withValues(alpha: 0.20);
    final tvFocusBorder = BorderSide(
      color: _tvFocusColor,
      width: _tvFocusBorderWidth,
    );

    // Helper: WidgetStateProperty that swaps to a thick yellow border
    // when the widget is focused. Used on every button type so D-pad
    // focus traversal is consistent across the app.
    WidgetStateProperty<BorderSide?> focusBorder() =>
        WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return tvFocusBorder;
          return null;
        });

    WidgetStateProperty<Color?> focusOverlay() =>
        WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return tvFocusFill;
          if (states.contains(WidgetState.hovered)) return tvFocusFill;
          return null;
        });

    return base.copyWith(
      // Generic focusColor — picks up by widgets that don't have their
      // own theme override (ListTile, InkWell, etc.). The Material
      // ripple uses this when a widget gains keyboard focus.
      focusColor: tvFocusFill,
      hoverColor: tvFocusFill,

      // IconButton — the workhorse on the AppBar + viewer toolbar.
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          side: focusBorder(),
          overlayColor: focusOverlay(),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ).copyWith(
          side: focusBorder(),
          overlayColor: focusOverlay(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ).copyWith(
          // Outlined buttons already have a border — override the
          // SIDE colour on focus to the yellow halo so the existing
          // outline becomes the focus indicator. Width also bumps.
          side: focusBorder(),
          overlayColor: focusOverlay(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom().copyWith(
          side: focusBorder(),
          overlayColor: focusOverlay(),
        ),
      ),
      // ListTile is heavily used in the shortcut rail + bookshelf row
      // menus. Default focus is a barely-visible tint; here we paint
      // the whole row yellow so the D-pad target is unmistakable.
      listTileTheme: ListTileThemeData(
        // selectedTileColor doubles as focused on most platforms when
        // wrapped in an InkWell. For explicit focus we also rely on
        // the global focusColor above.
        selectedTileColor: tvFocusFill,
        selectedColor: brightness == Brightness.light
            ? const Color(0xFF1A1300)
            : const Color(0xFFFFF8E1),
      ),
    );
  }
}
