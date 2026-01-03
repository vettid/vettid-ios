import SwiftUI

/// A pattern input grid for authentication
///
/// Supports 3x3 (default) or 4x4 grids. Pattern is captured by dragging
/// across dots, with visual feedback showing the path taken.
///
/// Pattern serialization follows cross-platform spec:
/// - 3x3 grid: positions 0-8, numbered left-to-right, top-to-bottom
/// - 4x4 grid: positions 0-15
/// - Minimum 4 points required
/// - No revisiting points
struct PatternGridView: View {

    // MARK: - Configuration

    let gridSize: Int
    let dotSize: CGFloat
    let dotSpacing: CGFloat
    let lineWidth: CGFloat
    let dotColor: Color
    let selectedDotColor: Color
    let lineColor: Color
    let errorColor: Color

    // MARK: - State

    @Binding var pattern: [Int]
    @Binding var isError: Bool
    @State private var currentPoint: CGPoint?
    @State private var dotPositions: [Int: CGPoint] = [:]

    // MARK: - Callbacks

    var onPatternComplete: (([Int]) -> Void)?

    // MARK: - Initialization

    init(
        gridSize: Int = 3,
        pattern: Binding<[Int]>,
        isError: Binding<Bool> = .constant(false),
        dotSize: CGFloat = 20,
        dotSpacing: CGFloat = 80,
        lineWidth: CGFloat = 4,
        dotColor: Color = .gray.opacity(0.5),
        selectedDotColor: Color = .blue,
        lineColor: Color = .blue.opacity(0.6),
        errorColor: Color = .red,
        onPatternComplete: (([Int]) -> Void)? = nil
    ) {
        self.gridSize = gridSize
        self._pattern = pattern
        self._isError = isError
        self.dotSize = dotSize
        self.dotSpacing = dotSpacing
        self.lineWidth = lineWidth
        self.dotColor = dotColor
        self.selectedDotColor = selectedDotColor
        self.lineColor = lineColor
        self.errorColor = errorColor
        self.onPatternComplete = onPatternComplete
    }

    // MARK: - Body

    var body: some View {
        let gridWidth = CGFloat(gridSize - 1) * dotSpacing + dotSize
        let gridHeight = gridWidth

        GeometryReader { geometry in
            ZStack {
                // Draw lines between selected dots
                Canvas { context, size in
                    drawPatternLines(context: context, size: size)
                }

                // Draw dots
                ForEach(0..<(gridSize * gridSize), id: \.self) { index in
                    let row = index / gridSize
                    let col = index % gridSize
                    let x = CGFloat(col) * dotSpacing + dotSize / 2
                    let y = CGFloat(row) * dotSpacing + dotSize / 2

                    Circle()
                        .fill(dotFillColor(for: index))
                        .frame(width: dotSize, height: dotSize)
                        .overlay(
                            Circle()
                                .stroke(dotStrokeColor(for: index), lineWidth: 2)
                        )
                        .position(x: x, y: y)
                        .background(
                            GeometryReader { dotGeometry in
                                Color.clear
                                    .onAppear {
                                        dotPositions[index] = CGPoint(x: x, y: y)
                                    }
                            }
                        )
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(at: value.location)
                    }
                    .onEnded { _ in
                        handleDragEnd()
                    }
            )
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(width: gridWidth + 40, height: gridHeight + 40)
    }

    // MARK: - Drawing

    private func drawPatternLines(context: GraphicsContext, size: CGSize) {
        guard pattern.count > 0 else { return }

        var path = Path()

        // Draw lines between selected dots
        for (index, dotIndex) in pattern.enumerated() {
            guard let position = dotPositions[dotIndex] else { continue }

            if index == 0 {
                path.move(to: position)
            } else {
                path.addLine(to: position)
            }
        }

        // Draw line to current finger position
        if let currentPoint = currentPoint, !pattern.isEmpty {
            path.addLine(to: currentPoint)
        }

        let strokeColor = isError ? errorColor : lineColor
        context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
    }

    private func dotFillColor(for index: Int) -> Color {
        if pattern.contains(index) {
            return isError ? errorColor.opacity(0.3) : selectedDotColor.opacity(0.3)
        }
        return dotColor.opacity(0.3)
    }

    private func dotStrokeColor(for index: Int) -> Color {
        if pattern.contains(index) {
            return isError ? errorColor : selectedDotColor
        }
        return dotColor
    }

    // MARK: - Gesture Handling

    private func handleDrag(at point: CGPoint) {
        currentPoint = point

        // Check if we're over a dot
        for (index, position) in dotPositions {
            let distance = hypot(point.x - position.x, point.y - position.y)
            let hitRadius = dotSize * 1.5 // Generous hit area

            if distance < hitRadius && !pattern.contains(index) {
                // Add dot to pattern
                pattern.append(index)
                isError = false

                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            }
        }
    }

    private func handleDragEnd() {
        currentPoint = nil

        if pattern.count >= PatternAuthenticator.minimumPatternLength {
            onPatternComplete?(pattern)
        } else if !pattern.isEmpty {
            // Pattern too short - show error
            isError = true

            // Clear after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pattern.removeAll()
                isError = false
            }
        }
    }
}

// MARK: - Pattern Authenticator

/// Handles pattern authentication logic
struct PatternAuthenticator {

    /// Minimum number of points required for a valid pattern
    static let minimumPatternLength = 4

    /// Supported grid sizes
    enum GridSize: Int, CaseIterable {
        case threeByThree = 3
        case fourByFour = 4

        var totalDots: Int { rawValue * rawValue }

        var displayName: String {
            switch self {
            case .threeByThree: return "3×3"
            case .fourByFour: return "4×4"
            }
        }
    }

    /// Serialize a pattern to a cross-platform string
    /// Format: comma-separated dot indices (e.g., "0,3,6,7,8" for L-shape)
    static func serialize(_ pattern: [Int]) -> String {
        pattern.map(String.init).joined(separator: ",")
    }

    /// Deserialize a pattern string back to an array
    static func deserialize(_ string: String) -> [Int]? {
        let components = string.split(separator: ",")
        let pattern = components.compactMap { Int($0) }
        guard pattern.count == components.count else { return nil }
        return pattern
    }

    /// Validate a pattern
    static func validate(_ pattern: [Int], gridSize: GridSize = .threeByThree) -> PatternValidationResult {
        // Check minimum length
        guard pattern.count >= minimumPatternLength else {
            return .tooShort(minimum: minimumPatternLength)
        }

        // Check for valid indices
        let maxIndex = gridSize.totalDots - 1
        for index in pattern {
            guard index >= 0 && index <= maxIndex else {
                return .invalidIndex(index)
            }
        }

        // Check for duplicates (no revisiting)
        let uniquePoints = Set(pattern)
        guard uniquePoints.count == pattern.count else {
            return .hasDuplicates
        }

        return .valid
    }

    /// Hash a pattern for storage
    /// Uses the same approach as PIN hashing for consistency
    static func hash(_ pattern: [Int]) -> String {
        let serialized = serialize(pattern)
        let data = Data(serialized.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Verify a pattern against a stored hash
    static func verify(_ pattern: [Int], against storedHash: String) -> Bool {
        let inputHash = hash(pattern)
        // Constant-time comparison to prevent timing attacks
        guard inputHash.count == storedHash.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(inputHash.utf8, storedHash.utf8) {
            result |= a ^ b
        }
        return result == 0
    }
}

// MARK: - Validation Result

enum PatternValidationResult: Equatable {
    case valid
    case tooShort(minimum: Int)
    case invalidIndex(Int)
    case hasDuplicates

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String? {
        switch self {
        case .valid:
            return nil
        case .tooShort(let minimum):
            return "Pattern must connect at least \(minimum) dots"
        case .invalidIndex(let index):
            return "Invalid pattern point: \(index)"
        case .hasDuplicates:
            return "Pattern cannot revisit dots"
        }
    }
}

// MARK: - SHA256 Import

import CryptoKit

// MARK: - Preview

#if DEBUG
struct PatternGridView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            Text("Draw a pattern")
                .font(.headline)

            PatternGridView(
                pattern: .constant([]),
                isError: .constant(false)
            ) { pattern in
                print("Pattern complete: \(PatternAuthenticator.serialize(pattern))")
            }

            Text("Connect at least 4 dots")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
#endif
