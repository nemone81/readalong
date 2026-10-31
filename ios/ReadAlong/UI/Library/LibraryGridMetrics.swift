import CoreGraphics

/// La regola della griglia della libreria, separata dalla vista perche' sia
/// testabile: quante colonne stanno in una data larghezza e quanto e' larga
/// ogni copertina.
///
/// Lo stesso `spacing` vale tra le celle e dai bordi dello schermo. Le colonne
/// sono quante piu' possibile con celle di almeno `minimumCellWidth`; lo spazio
/// che avanza allarga le celle, mai gli spazi. Su iPhone verticale (da 375 a
/// 440 pt) escono 2 colonne, su iPad da 4 in su.
enum LibraryGridMetrics {
    static let minimumCellWidth: CGFloat = 150
    static let spacing: CGFloat = 20

    /// Colonne per una griglia larga `width` (bordi inclusi). Almeno 1.
    static func columnCount(forWidth width: CGFloat) -> Int {
        let usable = width - 2 * spacing
        guard usable.isFinite, usable > 0 else { return 1 }
        return max(1, Int(((usable + spacing) / (minimumCellWidth + spacing)).rounded(.down)))
    }

    /// Larghezza di una cella per una griglia larga `width` (bordi inclusi).
    static func cellWidth(forWidth width: CGFloat) -> CGFloat {
        let count = CGFloat(columnCount(forWidth: width))
        let usable = max(0, width - 2 * spacing)
        return max(0, (usable - (count - 1) * spacing) / count)
    }
}
