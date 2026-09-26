import Foundation

/// The shape a book's cover is drawn in on the shelf, the book page and the
/// home cards. Book covers are portrait (2:3 for print, 3:4 for many
/// audiobook editions) while plenty of audiobook downloads carry square art;
/// 3:4 sits between them, so both fit whole with only a narrow margin, and
/// neither is cropped or stretched.
public enum SpokenWordCoverLayout {
    /// Width ÷ height of the cover frame.
    public static let aspectRatio: CGFloat = 3.0 / 4.0

    /// Frame height for a cover `width` wide, rounded to whole points so a
    /// row of covers lines up.
    public static func height(forWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return (width / aspectRatio).rounded()
    }

    /// Frame width for a cover `height` tall.
    public static func width(forHeight height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 0 }
        return (height * aspectRatio).rounded()
    }
}
