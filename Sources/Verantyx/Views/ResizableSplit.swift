import SwiftUI

// MARK: - ResizableHSplit
// Custom horizontal split container with drag divider.
// Obeys minWidth/maxWidth constraints on both panes so neither disappears.

struct ResizableHSplit<Left: View, Right: View>: View {
    var minLeft: CGFloat
    var maxLeft: CGFloat
    var minRight: CGFloat
    var initialLeft: CGFloat
    let left: Left
    let right: Right

    @State private var leftWidth: CGFloat
    @GestureState private var dragOffset: CGFloat = 0

    init(
        minLeft: CGFloat = 160,
        maxLeft: CGFloat = 480,
        minRight: CGFloat = 300,
        initialLeft: CGFloat = 240,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.minLeft    = minLeft
        self.maxLeft    = maxLeft
        self.minRight   = minRight
        self.initialLeft = initialLeft
        self.left  = left()
        self.right = right()
        _leftWidth = State(initialValue: initialLeft)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                left
                    .frame(width: clampedLeft(geo.size.width))
                    .clipped()

                divider(geo.size.width)

                right
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
    }

    private func clampedLeft(_ totalWidth: CGFloat) -> CGFloat {
        let proposed = leftWidth + dragOffset
        let maxAllowed = Swift.min(maxLeft, totalWidth - minRight - 6)
        return Swift.max(minLeft, Swift.min(proposed, maxAllowed))
    }

    private func divider(_ totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(width: 6)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1)
            )
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in state = value.translation.width }
                    .onEnded { value in
                        let proposed = leftWidth + value.translation.width
                        let maxAllowed = Swift.min(maxLeft, totalWidth - minRight - 6)
                        leftWidth = Swift.max(minLeft, Swift.min(proposed, maxAllowed))
                    }
            )
            .cursor(.resizeLeftRight)
    }
}

// MARK: - ResizableVSplit

struct ResizableVSplit<Top: View, Bottom: View>: View {
    var minTop: CGFloat
    var maxTop: CGFloat
    var minBottom: CGFloat
    var initialTop: CGFloat
    let top: Top
    let bottom: Bottom

    @State private var topHeight: CGFloat
    @GestureState private var dragOffset: CGFloat = 0

    init(
        minTop: CGFloat = 200,
        maxTop: CGFloat = 800,
        minBottom: CGFloat = 120,
        initialTop: CGFloat = 400,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.minTop    = minTop
        self.maxTop    = maxTop
        self.minBottom = minBottom
        self.initialTop = initialTop
        self.top    = top()
        self.bottom = bottom()
        _topHeight = State(initialValue: initialTop)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                top.frame(height: clampedTop(geo.size.height)).clipped()
                hDivider(geo.size.height)
                bottom.frame(maxHeight: .infinity).clipped()
            }
        }
    }

    private func clampedTop(_ totalHeight: CGFloat) -> CGFloat {
        let proposed = topHeight + dragOffset
        let maxAllowed = Swift.min(maxTop, totalHeight - minBottom - 6)
        return Swift.max(minTop, Swift.min(proposed, maxAllowed))
    }

    private func hDivider(_ totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(height: 6)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 1)
            )
            .gesture(
                DragGesture()
                    .updating($dragOffset) { v, state, _ in state = v.translation.height }
                    .onEnded { v in
                        let proposed = topHeight + v.translation.height
                        let maxAllowed = Swift.min(maxTop, totalHeight - minBottom - 6)
                        topHeight = Swift.max(minTop, Swift.min(proposed, maxAllowed))
                    }
            )
            .cursor(.resizeUpDown)
    }
}

// MARK: - Cursor modifier

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
