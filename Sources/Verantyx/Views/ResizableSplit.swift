import SwiftUI

// MARK: - ResizableHSplit
// Custom horizontal split container with drag divider.
//
// Fix: Replaced @GestureState dragOffset with @State leftWidth direct-update
// so the left pane width is mutated immediately on every onChanged event,
// eliminating the one-frame lag that caused jittery resizing.
// The divider hit area is also widened to 8pt for easier grabbing.

struct ResizableHSplit<Left: View, Right: View>: View {
    var minLeft: CGFloat
    var maxLeft: CGFloat
    var minRight: CGFloat

    let left: Left
    let right: Right

    @State private var leftWidth: CGFloat
    @State private var isDragging: Bool = false

    init(
        minLeft: CGFloat = 160,
        maxLeft: CGFloat = 480,
        minRight: CGFloat = 300,
        initialLeft: CGFloat = 240,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.minLeft   = minLeft
        self.maxLeft   = maxLeft
        self.minRight  = minRight
        self.left  = left()
        self.right = right()
        _leftWidth = State(initialValue: initialLeft)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                left
                    .frame(width: clampedLeft(geo.size.width, proposed: leftWidth))
                    .clipped()

                divider(totalWidth: geo.size.width)

                right
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
    }

    private func clampedLeft(_ totalWidth: CGFloat, proposed: CGFloat) -> CGFloat {
        let maxAllowed = Swift.min(maxLeft, totalWidth - minRight - 8)
        return Swift.max(minLeft, Swift.min(proposed, maxAllowed))
    }

    private func divider(totalWidth: CGFloat) -> some View {
        ZStack {
            // Visual stripe (1pt)
            Rectangle()
                .fill(isDragging
                      ? Color(red: 0.4, green: 0.65, blue: 1.0).opacity(0.60)
                      : Color.white.opacity(0.10))
                .frame(width: 1)
                .animation(.easeInOut(duration: 0.12), value: isDragging)

            // Invisible 8pt hit area — wider = easier to grab
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
        }
        .frame(width: 8)
        .cursor(.resizeLeftRight)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging { isDragging = true }
                    // Commit width directly every event — no accumulated offset lag
                    let proposed = leftWidth + value.translation.width
                    leftWidth = clampedLeft(totalWidth, proposed: proposed)
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

// MARK: - ResizableVSplit

struct ResizableVSplit<Top: View, Bottom: View>: View {
    var minTop: CGFloat
    var maxTop: CGFloat
    var minBottom: CGFloat

    let top: Top
    let bottom: Bottom

    @State private var topHeight: CGFloat
    @State private var isDragging: Bool = false

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
        self.top    = top()
        self.bottom = bottom()
        _topHeight = State(initialValue: initialTop)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                top
                    .frame(height: clampedTop(geo.size.height, proposed: topHeight))
                    .clipped()
                hDivider(totalHeight: geo.size.height)
                bottom
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
        }
    }

    private func clampedTop(_ totalHeight: CGFloat, proposed: CGFloat) -> CGFloat {
        let maxAllowed = Swift.min(maxTop, totalHeight - minBottom - 8)
        return Swift.max(minTop, Swift.min(proposed, maxAllowed))
    }

    private func hDivider(totalHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(isDragging
                      ? Color(red: 0.4, green: 0.65, blue: 1.0).opacity(0.60)
                      : Color.white.opacity(0.10))
                .frame(height: 1)
                .animation(.easeInOut(duration: 0.12), value: isDragging)

            Color.clear
                .frame(height: 8)
                .contentShape(Rectangle())
        }
        .frame(height: 8)
        .cursor(.resizeUpDown)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging { isDragging = true }
                    let proposed = topHeight + value.translation.height
                    topHeight = clampedTop(totalHeight, proposed: proposed)
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
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
