//
//  Created by Mike Griebling on 2022-12-31.
//  Translated from an Objective-C implementation by Kostub Deshmukh.
//
//  This software may be modified and distributed under the terms of the
//  MIT license. See the LICENSE file for details.
//

import Foundation
import QuartzCore
import CoreText
import SwiftUI

func isIos6Supported() -> Bool {
    if !MTDisplay.initialized {
#if os(iOS)
        let reqSysVer = "6.0"
        let currSysVer = UIDevice.current.systemVersion
        if currSysVer.compare(reqSysVer, options: .numeric) != .orderedAscending {
            MTDisplay.supported = true
        }
#else
        MTDisplay.supported = true
#endif
        MTDisplay.initialized = true
    }
    return MTDisplay.supported
}

// The Downshift protocol allows an MTDisplay to be shifted down by a given amount.
protocol DownShift {
    var shiftDown: CGFloat { get set }
}

// MARK: - MTDisplay

/// The base class for rendering a math equation.
public class MTDisplay: NSObject {

    // needed for isIos6Supported() func above
    static var initialized = false
    static var supported = false

    /// Draws itself in the given graphics context.
    public func draw(_ context: CGContext) {

        context.saveGState()

        if self.localBackgroundColor != nil {
            context.setBlendMode(.normal)
            context.setFillColor(self.localBackgroundColor!.cgColor)
            context.fill(self.displayBounds())
        }

        if needsBorder {
            context.setStrokeColor(MTColor.black.cgColor)
            context.setLineWidth(1.0)
            let bounds = CGRect(x: position.x - 3, y: position.y - descent, width: width + 6, height: ascent + descent)
            context.stroke(bounds)
        }

        context.restoreGState()
    }

    /// Gets the bounding rectangle for the MTDisplay
    func displayBounds() -> CGRect {
        CGRect(x: self.position.x, y: self.position.y - self.descent, width: self.width, height: self.ascent + self.descent)
    }

    /// For debugging. Shows the object in quick look in Xcode.
#if os(iOS)
    func debugQuickLookObject() -> Any {
        let size = CGSize(width: self.width, height: self.ascent + self.descent)
        UIGraphicsBeginImageContext(size)

        // get a reference to that context we created
        let context = UIGraphicsGetCurrentContext()!
        // translate/flip the graphics context (for transforming from CG* coords to UI* coords
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        // move the position to (0,0)
        context.translateBy(x: -self.position.x, y: -self.position.y)

        // Move the line up by self.descent
        context.translateBy(x: 0, y: self.descent)
        // Draw self on context
        self.draw(context)

        // generate a new UIImage from the graphics context we drew onto
        let img = UIGraphicsGetImageFromCurrentImageContext()
        return img as Any
    }
#endif

    /// The distance from the axis to the top of the display
    public var ascent: CGFloat = 0
    /// The distance from the axis to the bottom of the display
    public var descent: CGFloat = 0
    /// The width of the display
    public var width: CGFloat = 0
    /// Position of the display with respect to the parent view or display.
    var position = CGPoint.zero
    /// The range of characters supported by this item
    public var range: NSRange=NSRange(location: 0, length: 0)
    /// Whether the display has a subscript/superscript following it.
    public var hasScript: Bool = false
    /// The text color for this display
    var textColor: MTColor?
    /// The local color, if the color was mutated local with the color command
    var localTextColor: MTColor?
    /// The background color for this display
    var localBackgroundColor: MTColor?
    var needsBorder: Bool = false

}

/// Special class to be inherited from that implements the DownShift protocol
class MTDisplayDS: MTDisplay, DownShift {

    var shiftDown: CGFloat = 0

}

// MARK: - MTCTLineDisplay

/// A rendering of a single CTLine as an MTDisplay
public class MTCTLineDisplay: MTDisplay {

    /// The CTLine being displayed
    public var line: CTLine!
    /// The attributed string used to generate the CTLineRef. Note setting this does not reset the dimensions of
    /// the display. So set only when
    var attributedString: NSAttributedString? {
        didSet {
            line = CTLineCreateWithAttributedString(attributedString!)
        }
    }

    /// An array of MTMathAtoms that this CTLine displays. Used for indexing back into the MTMathList
    public fileprivate(set) var atoms = [MTMathAtom]()

    init(withString attrString: NSAttributedString?, position: CGPoint, range: NSRange, font: MTFont?, atoms: [MTMathAtom]) {
        super.init()
        self.position = position
        self.attributedString = attrString
        self.line = CTLineCreateWithAttributedString(attrString!)
        self.range = range
        self.atoms = atoms
        // We can't use typographic bounds here as the ascent and descent returned are for the font and not for the line.
        self.width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if isIos6Supported() {
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            self.ascent = max(0, bounds.maxY - 0)
            self.descent = max(0, 0 - bounds.minY)
            // TODO: Should we use this width vs the typographic width? They are slightly different. Don't know why.
            // _width = CGRectGetMaxX(bounds);
        } else {
            // Our own implementation of the ios6 function to get glyph path bounds.
            self.computeDimensions(font)
        }
    }

    override var textColor: MTColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            guard let attributedString,
                  let attrStr = attributedString.mutableCopy() as? NSMutableAttributedString else {
                return
            }
            let foregroundColor = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            attrStr.addAttribute(foregroundColor, value: self.textColor!.cgColor, range: NSRange(location: 0, length: attrStr.length))
            self.attributedString = attrStr
        }
    }

    func computeDimensions(_ font: MTFont?) {
        let runs = CTLineGetGlyphRuns(line) as NSArray
        for obj in runs {
            guard let run = obj as? CTRun?,
                  let run else {
                continue
            }
            let numGlyphs = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph]()
            glyphs.reserveCapacity(numGlyphs)
            CTRunGetGlyphs(run, CFRangeMake(0, numGlyphs), &glyphs)
            guard let font else { continue }
            let bounds = CTFontGetBoundingRectsForGlyphs(font.ctFont, .horizontal, glyphs, nil, numGlyphs)
            let ascent = max(0, bounds.maxY - 0)
            // Descent is how much the line goes below the origin. However if the line is all above the origin, then descent can't be negative.
            let descent = max(0, 0 - bounds.minY)
            if ascent > self.ascent {
                self.ascent = ascent
            }
            if descent > self.descent {
                self.descent = descent
            }
        }
    }

    override public func draw(_ context: CGContext) {
        super.draw(context)
        context.saveGState()

        context.textPosition = self.position
        CTLineDraw(line, context)

        context.restoreGState()
    }

}

// MARK: - MTMathListDisplay

/// An MTLine is a rendered form of MTMathList in one line.
/// It can render itself using the draw method.
public class MTMathListDisplay: MTDisplay {

    /**
          The type of position for a line, i.e. subscript/superscript or regular.
     */
    public enum LinePosition: Int {
        /// Regular
        case regular
        /// Positioned at a subscript
        case ssubscript
        /// Positioned at a superscript
        case superscript
    }

    /// Where the line is positioned
    public var type: LinePosition = .regular
    /// An array of MTDisplays which are positioned relative to the position of the
    /// the current display.
    public fileprivate(set) var subDisplays = [MTDisplay]()
    /// If a subscript or superscript this denotes the location in the parent MTList. For a
    /// regular list this is NSNotFound
    public var index: Int = 0

    init(withDisplays displays: [MTDisplay], range: NSRange) {
        super.init()
        self.subDisplays = displays
        self.position = CGPoint.zero
        self.type = .regular
        self.index = NSNotFound
        self.range = range
        self.recomputeDimensions()
    }

    override var textColor: MTColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            for displayAtom in self.subDisplays {
                if displayAtom.localTextColor == nil {
                    displayAtom.textColor = newValue
                } else {
                    displayAtom.textColor = displayAtom.localTextColor
                }
            }
        }
    }

    override public func draw(_ context: CGContext) {
        super.draw(context)
        context.saveGState()

        // Make the current position the origin as all the positions of the sub atoms are relative to the origin.
        context.translateBy(x: self.position.x, y: self.position.y)
        context.textPosition = CGPoint.zero

        // draw each atom separately
        for displayAtom in self.subDisplays {
            displayAtom.draw(context)
        }

        context.restoreGState()
    }

    func recomputeDimensions() {
        var max_ascent: CGFloat = 0
        var max_descent: CGFloat = 0
        var max_width: CGFloat = 0
        for atom in self.subDisplays {
            let ascent = max(0, atom.position.y + atom.ascent)
            if ascent > max_ascent {
                max_ascent = ascent
            }

            let descent = max(0, 0 - (atom.position.y - atom.descent))
            if descent > max_descent {
                max_descent = descent
            }
            let width = atom.width + atom.position.x
            if width > max_width {
                max_width = width
            }
        }
        self.ascent = max_ascent
        self.descent = max_descent
        self.width = max_width
    }

}

// MARK: - MTFractionDisplay

/// Rendering of an MTFraction as an MTDisplay
public class MTFractionDisplay: MTDisplay {

    /** A display representing the numerator of the fraction. Its position is relative
     to the parent and is not treated as a sub-display.
     */
    public fileprivate(set) var numerator: MTMathListDisplay?
    /** A display representing the denominator of the fraction. Its position is relative
     to the parent is not treated as a sub-display.
     */
    public fileprivate(set) var denominator: MTMathListDisplay?

    var numeratorUp: CGFloat=0 { didSet { self.updateNumeratorPosition() } }
    var denominatorDown: CGFloat=0 { didSet { self.updateDenominatorPosition() } }
    var linePosition: CGFloat=0
    var lineThickness: CGFloat=0

    init(withNumerator numerator: MTMathListDisplay?, denominator: MTMathListDisplay?, position: CGPoint, range: NSRange) {
        super.init()
        self.numerator = numerator
        self.denominator = denominator
        self.position = position
        self.range = range
        assert(self.range.length == 1, "Fraction range length not 1 - range (\(range.location), \(range.length)")
    }

    override public var ascent: CGFloat {
        get { numerator!.ascent + self.numeratorUp }
        set { super.ascent = newValue }
    }

    override public var descent: CGFloat {
        get { denominator!.descent + self.denominatorDown }
        set { super.descent = newValue }
    }

    override public var width: CGFloat {
        get { max(numerator!.width, denominator!.width) }
        set { super.width = newValue }
    }

    func updateDenominatorPosition() {
        guard denominator != nil else { return }
        denominator!.position = CGPoint(x: self.position.x + (self.width - denominator!.width)/2, y: self.position.y - self.denominatorDown)
    }

    func updateNumeratorPosition() {
        guard numerator != nil else { return }
        numerator!.position = CGPoint(x: self.position.x + (self.width - numerator!.width)/2, y: self.position.y + self.numeratorUp)
    }

    override var position: CGPoint {
        get { super.position }
        set {
            super.position = newValue
            self.updateDenominatorPosition()
            self.updateNumeratorPosition()
        }
    }

    override var textColor: MTColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            numerator?.textColor = newValue
            denominator?.textColor = newValue
        }
    }

    override public func draw(_ context: CGContext) {
        super.draw(context)
        numerator?.draw(context)
        denominator?.draw(context)

        context.saveGState()

        self.textColor?.setStroke()

        // draw the horizontal line
        // Note: line thickness of 0 draws the thinnest possible line - we want no line so check for 0s
        if self.lineThickness > 0 {
            let path = MTBezierPath()
            path.move(to: CGPoint(x: self.position.x, y: self.position.y + self.linePosition))
            path.addLine(to: CGPoint(x: self.position.x + self.width, y: self.position.y + self.linePosition))
            path.lineWidth = self.lineThickness
            path.stroke()
        }

        context.restoreGState()
    }

}

// MARK: - MTRadicalDisplay

/// Rendering of an MTRadical as an MTDisplay
class MTRadicalDisplay: MTDisplay {

    /** A display representing the radicand of the radical. Its position is relative
     to the parent is not treated as a sub-display.
     */
    public fileprivate(set) var radicand: MTMathListDisplay?
    /** A display representing the degree of the radical. Its position is relative
     to the parent is not treated as a sub-display.
     */
    public fileprivate(set) var degree: MTMathListDisplay?

    override var position: CGPoint {
        get { super.position }
        set {
            super.position = newValue
            self.updateRadicandPosition()
        }
    }

    override var textColor: MTColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            self.radicand?.textColor = newValue
            self.degree?.textColor = newValue
        }
    }

    private var _radicalGlyph: MTDisplay?
    private var _radicalShift: CGFloat=0

    var topKern: CGFloat=0
    var lineThickness: CGFloat=0

    init(withRadicand radicand: MTMathListDisplay?, glyph: MTDisplay, position: CGPoint, range: NSRange) {
        super.init()
        self.radicand = radicand
        _radicalGlyph = glyph
        _radicalShift = 0

        self.position = position
        self.range = range
    }

    func setDegree(_ degree: MTMathListDisplay?, fontMetrics: MTFontMathTable?) {
        // sets up the degree of the radical
        var kernBefore = fontMetrics!.radicalKernBeforeDegree
        let kernAfter = fontMetrics!.radicalKernAfterDegree
        let raise = fontMetrics!.radicalDegreeBottomRaisePercent * (self.ascent - self.descent)

        // The layout is:
        // kernBefore, raise, degree, kernAfter, radical
        self.degree = degree

        // the radical is now shifted by kernBefore + degree.width + kernAfter
        _radicalShift = kernBefore + degree!.width + kernAfter
        if _radicalShift < 0 {
            // we can't have the radical shift backwards, so instead we increase the kernBefore such
            // that _radicalShift will be 0.
            kernBefore -= _radicalShift
            _radicalShift = 0
        }

        // Note: position of degree is relative to parent.
        self.degree!.position = CGPoint(x: self.position.x + kernBefore, y: self.position.y + raise)
        // Update the width by the _radicalShift
        self.width = _radicalShift + _radicalGlyph!.width + self.radicand!.width
        // update the position of the radicand
        self.updateRadicandPosition()
    }

    func updateRadicandPosition() {
        // The position of the radicand includes the position of the MTRadicalDisplay
        // This is to make the positioning of the radical consistent with fractions and
        // have the cursor position finding algorithm work correctly.
        // move the radicand by the width of the radical sign
        self.radicand!.position = CGPoint(x: self.position.x + _radicalShift + _radicalGlyph!.width, y: self.position.y)
    }

    override public func draw(_ context: CGContext) {
        super.draw(context)

        // draw the radicand & degree at its position
        self.radicand?.draw(context)
        self.degree?.draw(context)

        context.saveGState()
        self.textColor?.setStroke()
        self.textColor?.setFill()

        // Make the current position the origin as all the positions of the sub atoms are relative to the origin.
        context.translateBy(x: self.position.x + _radicalShift, y: self.position.y)
        context.textPosition = CGPoint.zero

        // Draw the glyph.
        _radicalGlyph?.draw(context)

        // Draw the VBOX
        // for the kern of, we don't need to draw anything.
        let heightFromTop = topKern

        // draw the horizontal line with the given thickness
        let path = MTBezierPath()
        let lineStart = CGPoint(x: _radicalGlyph!.width, y: self.ascent - heightFromTop - self.lineThickness / 2) // subtract half the line thickness to center the line
        let lineEnd = CGPoint(x: lineStart.x + self.radicand!.width, y: lineStart.y)
        path.move(to: lineStart)
        path.addLine(to: lineEnd)
        path.lineWidth = lineThickness
        path.lineCapStyle = .round
        path.stroke()

        context.restoreGState()
    }
}

// MARK: - MTGlyphDisplay

/// Rendering a glyph as a display
class MTGlyphDisplay: MTDisplayDS {

    var glyph: CGGlyph!
    var font: MTFont?

    init(withGlpyh glyph: CGGlyph, range: NSRange, font: MTFont?) {
        super.init()
        self.font = font
        self.glyph = glyph

        self.position = CGPoint.zero
        self.range = range
    }

    override public func draw(_ context: CGContext) {
        super.draw(context)
        context.saveGState()

        self.textColor?.setFill()

        // Make the current position the origin as all the positions of the sub atoms are relative to the origin.

        context.translateBy(x: self.position.x, y: self.position.y - self.shiftDown)
        context.textPosition = CGPoint.zero

        var pos = CGPoint.zero
        CTFontDrawGlyphs(font!.ctFont, &glyph, &pos, 1, context)

        context.restoreGState()
    }

    override var ascent: CGFloat {
        get { super.ascent - self.shiftDown }
        set { super.ascent = newValue }
    }

    override var descent: CGFloat {
        get { super.descent + self.shiftDown }
        set { super.descent = newValue }
    }
}

// MARK: - MTGlyphConstructionDisplay

class MTGlyphConstructionDisplay: MTDisplayDS {
    var glyphs = [CGGlyph]()
    var positions = [CGPoint]()
    var font: MTFont?
    var numGlyphs: Int=0

    init(withGlyphs glyphs: [NSNumber?], offsets: [NSNumber?], font: MTFont?) {
        super.init()
        assert(glyphs.count == offsets.count, "Glyphs and offsets need to match")
        self.numGlyphs = glyphs.count
        self.glyphs = [CGGlyph](repeating: CGGlyph(), count: self.numGlyphs)  // malloc(sizeof(CGGlyph) * _numGlyphs);
        self.positions = [CGPoint](repeating: CGPoint.zero, count: self.numGlyphs) // malloc(sizeof(CGPoint) * _numGlyphs);
        for i in 0 ..< self.numGlyphs {
            self.glyphs[i] = glyphs[i]!.uint16Value
            self.positions[i] = CGPoint(x: 0, y: CGFloat(offsets[i]!.floatValue))
        }
        self.font = font
        self.position = CGPoint.zero
    }

    override public func draw(_ context: CGContext) {
        super.draw(context)
        context.saveGState()

        self.textColor?.setFill()

        // Make the current position the origin as all the positions of the sub atoms are relative to the origin.
        context.translateBy(x: self.position.x, y: self.position.y - self.shiftDown)
        context.textPosition = CGPoint.zero

        // Draw the glyphs.
        CTFontDrawGlyphs(font!.ctFont, glyphs, positions, numGlyphs, context)

        context.restoreGState()
    }

    override var ascent: CGFloat {
        get { super.ascent - self.shiftDown }
        set { super.ascent = newValue }
    }

    override var descent: CGFloat {
        get { super.descent + self.shiftDown }
        set { super.descent = newValue }
    }

}

// MARK: - MTLargeOpLimitsDisplay

/// Rendering a large operator with limits as an MTDisplay
class MTLargeOpLimitsDisplay: MTDisplay {

    /** A display representing the upper limit of the large operator. Its position is relative
     to the parent is not treated as a sub-display.
     */
    var upperLimit: MTMathListDisplay?
    /** A display representing the lower limit of the large operator. Its position is relative
     to the parent is not treated as a sub-display.
     */
    var lowerLimit: MTMathListDisplay?

    var limitShift: CGFloat=0
    var upperLimitGap: CGFloat=0 { didSet { self.updateUpperLimitPosition() } }
    var lowerLimitGap: CGFloat=0 { didSet { self.updateLowerLimitPosition() } }
    var extraPadding: CGFloat=0

    var nucleus: MTDisplay?

    init(withNucleus nucleus: MTDisplay?, upperLimit: MTMathListDisplay?, lowerLimit: MTMathListDisplay?, limitShift: CGFloat, extraPadding: CGFloat) {
        super.init()
        self.upperLimit = upperLimit
        self.lowerLimit = lowerLimit
        self.nucleus = nucleus

        var maxWidth = max(nucleus!.width, upperLimit?.width ?? 0)
        maxWidth = max(maxWidth, lowerLimit?.width ?? 0)

        self.limitShift = limitShift
        self.upperLimitGap = 0
        self.lowerLimitGap = 0
        self.extraPadding = extraPadding  // corresponds to \xi_13 in TeX
        self.width = maxWidth
    }

    override var ascent: CGFloat {
        get {
            if self.upperLimit != nil {
                return nucleus!.ascent + extraPadding + self.upperLimit!.ascent + upperLimitGap + self.upperLimit!.descent
            } else {
                return nucleus!.ascent
            }
        }
        set { super.ascent = newValue }
    }

    override var descent: CGFloat {
        get {
            if self.lowerLimit != nil {
                return nucleus!.descent + extraPadding + lowerLimitGap + self.lowerLimit!.descent + self.lowerLimit!.ascent
            } else {
                return nucleus!.descent
            }
        }
        set { super.descent = newValue }
    }

    override var position: CGPoint {
        get { super.position }
        set {
            super.position = newValue
            self.updateLowerLimitPosition()
            self.updateUpperLimitPosition()
            self.updateNucleusPosition()
        }
    }

    func updateLowerLimitPosition() {
        if self.lowerLimit != nil {
            // The position of the lower limit includes the position of the MTLargeOpLimitsDisplay
            // This is to make the positioning of the radical consistent with fractions and radicals
            // Move the starting point to below the nucleus leaving a gap of _lowerLimitGap and subtract
            // the ascent to to get the baseline. Also center and shift it to the left by _limitShift.
            self.lowerLimit!.position = CGPoint(
                x: self.position.x - limitShift + (self.width - lowerLimit!.width) / 2,
                y: self.position.y - nucleus!.descent - lowerLimitGap - self.lowerLimit!.ascent
            )
        }
    }

    func updateUpperLimitPosition() {
        if self.upperLimit != nil {
            // The position of the upper limit includes the position of the MTLargeOpLimitsDisplay
            // This is to make the positioning of the radical consistent with fractions and radicals
            // Move the starting point to above the nucleus leaving a gap of _upperLimitGap and add
            // the descent to to get the baseline. Also center and shift it to the right by _limitShift.
            self.upperLimit!.position = CGPoint(
                x: self.position.x + limitShift + (self.width - self.upperLimit!.width) / 2,
                y: self.position.y + nucleus!.ascent + upperLimitGap + self.upperLimit!.descent
            )
        }
    }

    func updateNucleusPosition() {
        // Center the nucleus
        nucleus?.position = CGPoint(x: self.position.x + (self.width - nucleus!.width)/2, y: self.position.y)
    }

    override var textColor: MTColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            self.upperLimit?.textColor = newValue
            self.lowerLimit?.textColor = newValue
            nucleus?.textColor = newValue
        }
    }

    override func draw(_ context: CGContext) {
        super.draw(context)
        // Draw the elements.
        self.upperLimit?.draw(context)
        self.lowerLimit?.draw(context)
        nucleus?.draw(context)
    }

}

// MARK: - MTLineDisplay

/// Rendering of an list with an overline or underline
class MTLineDisplay: MTDisplay {

    /** A display representing the inner list that is underlined. Its position is relative
     to the parent is not treated as a sub-display.
     */
    var inner: MTMathListDisplay?
    var lineShiftUp: CGFloat=0
    var lineThickness: CGFloat=0

    init(withInner inner: MTMathListDisplay?, position: CGPoint, range: NSRange) {
        super.init()
        self.inner = inner

        self.position = position
        self.range = range
    }

    override var textColor: MTColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            inner?.textColor = newValue
        }
    }

    override var position: CGPoint {
        get { super.position }
        set {
            super.position = newValue
            self.updateInnerPosition()
        }
    }

    override func draw(_ context: CGContext) {
        super.draw(context)
        self.inner?.draw(context)

        context.saveGState()

        self.textColor?.setStroke()

        // draw the horizontal line
        let path = MTBezierPath()
        let lineStart = CGPoint(x: self.position.x, y: self.position.y + self.lineShiftUp)
        let lineEnd = CGPoint(x: lineStart.x + self.inner!.width, y: lineStart.y)
        path.move(to: lineStart)
        path.addLine(to: lineEnd)
        path.lineWidth = self.lineThickness
        path.stroke()

        context.restoreGState()
    }

    func updateInnerPosition() {
        self.inner?.position = CGPoint(x: self.position.x, y: self.position.y)
    }

}

// MARK: - MTAccentDisplay

/// Rendering an accent as a display
class MTAccentDisplay: MTDisplay {

    /** A display representing the inner list that is accented. Its position is relative
     to the parent is not treated as a sub-display.
     */
    var accentee: MTMathListDisplay?

    /** A display representing the accent. Its position is relative to the current display.
     */
    var accent: MTGlyphDisplay?

    init(withAccent glyph: MTGlyphDisplay?, accentee: MTMathListDisplay?, range: NSRange) {
        super.init()
        self.accent = glyph
        self.accentee = accentee
        self.accentee?.position = CGPoint.zero
        self.range = range
    }

    override var textColor: MTColor? {
        get { super.textColor }
        set {
            super.textColor = newValue
            accentee?.textColor = newValue
            accent?.textColor = newValue
        }
    }

    override var position: CGPoint {
        get { super.position }
        set {
            super.position = newValue
            self.updateAccenteePosition()
        }
    }

    func updateAccenteePosition() {
        self.accentee?.position = CGPoint(x: self.position.x, y: self.position.y)
    }

    override func draw(_ context: CGContext) {
        super.draw(context)
        self.accentee?.draw(context)

        context.saveGState()
        context.translateBy(x: self.position.x, y: self.position.y)
        context.textPosition = CGPoint.zero

        self.accent?.draw(context)

        context.restoreGState()
    }

}
