import SwiftUI

extension View {
    /// Sizes the content of a sheet. macOS keeps the fixed or minimum size the sheet always
    /// had (the same `.frame(...)` arguments, so Mac sheets do not resize); iOS fills the sheet,
    /// because a phone never gets a fixed width — a `.frame(width: 460)` there clips the sheet
    /// at the screen edge.
    ///
    /// Pass either the fixed pair (`width:`/`height:` → `.frame(width:height:)`) or the
    /// flexible set (`minWidth:`/`idealWidth:`/`minHeight:`/`idealHeight:` →
    /// `.frame(minWidth:idealWidth:minHeight:idealHeight:)`), matching the call it replaces.
    /// With both, the fixed frame is applied first. Parameters are in SwiftUI's own `.frame`
    /// order, so converting an existing site is a pure rename: `.frame(` becomes `.sheetFrame(`.
    @ViewBuilder
    func sheetFrame(
        width: CGFloat? = nil, height: CGFloat? = nil,
        minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil
    ) -> some View {
        #if os(macOS)
            let fixed = width != nil || height != nil
            let flexible = minWidth != nil || minHeight != nil || idealWidth != nil || idealHeight != nil
            if fixed, flexible {
                frame(width: width, height: height)
                    .frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
            } else if fixed {
                frame(width: width, height: height)
            } else if flexible {
                frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
            } else {
                self
            }
        #else
            frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
