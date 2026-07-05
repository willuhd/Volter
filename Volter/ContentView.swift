//
//  ContentView.swift
//  Volter
//
//  Created by Will on 7/4/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    // Current working states
    @State private var turbo = false
    @State private var lowPowerMode = "Off"
    @State private var powerLimit: Double = 14.0

    // Baseline states to track if "something changes"
    @State private var baseTurbo = false
    @State private var baseLowPowerMode = "Off"
    @State private var basePowerLimit: Double = 14.0

    @State private var showingSettings = false
    
    // High-resolution accumulator to prevent choppy trackpad/mouse drag interactions
    @State private var dragPowerAccumulator: Double = 14.0

    let modes = ["Off", "On", "Battery"]

    // Computed property to detect state divergence
    var hasChanges: Bool {
        turbo != baseTurbo ||
        lowPowerMode != baseLowPowerMode ||
        Int(powerLimit) != Int(basePowerLimit)
    }

    var body: some View {
        VStack(spacing: 0) {
            
            // Header Row: Statically positioned and locked vertically to eliminate Y shifts
            HStack(alignment: .center) {
                // Left Title / Checkbox (Cross-fade transition)
                ZStack(alignment: .leading) {
                    if !showingSettings {
                        Toggle("Turbo", isOn: $turbo)
                            .toggleStyle(.checkbox)
                            .font(.body)
                            .transition(.opacity)
                    } else {
                        Text("Volter")
                            .font(.system(size: 16, weight: .bold))
                            .transition(.opacity)
                    }
                }
                
                Spacer()

                // Right static alignment container (Keeps the check button perfectly static)
                HStack(spacing: 8) {
                    if !showingSettings {
                        // Settings Button (slides out cleanly)
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showingSettings = true
                            }
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .frame(width: 20, height: 20)
                                .background(Color(NSColor.controlColor))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }

                    // Checkmark Button: Anchored firmly (never moves vertically or horizontally)
                    Button(action: {
                        if showingSettings {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showingSettings = false
                            }
                        } else {
                            baseTurbo = turbo
                            baseLowPowerMode = lowPowerMode
                            basePowerLimit = powerLimit
                        }
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(showingSettings ? .secondary : (hasChanges ? .white : .secondary))
                            .frame(width: 20, height: 20)
                            .background(showingSettings ? Color(NSColor.controlColor) : (hasChanges ? Color.blue : Color(NSColor.controlColor)))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .frame(height: 24)
            
            Spacer(minLength: 12)

            // Dynamic Body Container: Horizontal slide mechanism (No rubber band bounce)
            HStack(spacing: 0) {
                mainBody
                    .frame(width: 290, height: 77)
                    .padding(.horizontal, 16)
                
                settingsBody
                    .frame(width: 290, height: 77)
                    .padding(.horizontal, 16)
            }
            .frame(width: 580, height: 77, alignment: .leading)
            .offset(x: showingSettings ? -290 : 0)
        }
        .frame(width: 290, height: 125, alignment: .topLeading)
    }

    // MARK: - Main Panel View
    private var mainBody: some View {
        VStack(spacing: 12) {
            // Row 2: Low Power Mode
            HStack(alignment: .center) {
                Text("Low Power Mode:")
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                
                Spacer(minLength: 12)
                
                Picker("", selection: $lowPowerMode) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .frame(height: 22)

            // Row 3: Power Limit
            HStack(alignment: .center) {
                Text("Power Limit:")
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                CustomTickSlider(value: Binding(
                    get: { min(powerLimit, 24.0) },
                    set: { powerLimit = $0 }
                ), range: 0...24)

                // High-resolution Drag Readout Label (No white background frame)
                ZStack {
                    Text(Int(powerLimit) == 0 ? "Off" : "\(Int(powerLimit))W")
                        .font(.body)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 45, height: 20, alignment: .trailing)
                    
                    RelativeDragTracker(
                        onDragStart: {
                            dragPowerAccumulator = powerLimit
                        },
                        onDrag: { deltaX in
                            // Trackpad-optimized continuous divider
                            let newAccumulator = dragPowerAccumulator + (deltaX / 11.0)
                            dragPowerAccumulator = min(max(newAccumulator, 0), 45)
                            powerLimit = round(dragPowerAccumulator)
                        }
                    )
                    .frame(width: 45, height: 20)
                }
            }
            .frame(height: 22)
        }
    }

    // MARK: - Settings Panel View
    private var settingsBody: some View {
        VStack {
            Spacer()
            Button(action: {
                NSApp.terminate(nil)
            }) {
                Text("Quit Volter")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(Color(NSColor.controlColor))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

// MARK: - Pointing-Up Pentagon Thumb Shape
struct PointingUpThumbShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.45))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.45))
        path.closeSubpath()
        return path
    }
}

// MARK: - Modernized Custom Tick Slider
struct CustomTickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tickCount: Int = 25 // 0 to 24 inclusive

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbWidth: CGFloat = 12
            let usableWidth = width - thumbWidth
            
            let percentage = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbX = percentage * usableWidth + (thumbWidth / 2)
            
            ZStack {
                // 1. Ticks: Modern, crisp design
                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { i in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 1, height: 6)
                        if i < (tickCount - 1) {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, thumbWidth / 2)
                .offset(y: -7)
                
                // 2. Track: Robust modern rounded capsule (3pt height)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.gray.opacity(0.25))
                    .frame(height: 3)
                    .padding(.horizontal, thumbWidth / 2)
                
                // 3. Thumb: Pentagon shape pointing up
                PointingUpThumbShape()
                    .fill(Color.white)
                    .overlay(
                        PointingUpThumbShape()
                            .stroke(Color.gray.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: thumbWidth, height: 13)
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 1)
                    .offset(x: thumbX - (width / 2), y: 2.5)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gestureValue in
                        let locationX = gestureValue.location.x - (thumbWidth / 2)
                        let clampedX = min(max(locationX, 0), usableWidth)
                        let newPercent = clampedX / usableWidth
                        let calculatedValue = Double(newPercent) * (range.upperBound - range.lowerBound) + range.lowerBound
                        
                        // Enforce integer increments (stepping at each watt)
                        value = round(calculatedValue)
                    }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - Cocoa Relative Drag Tracker
struct RelativeDragTracker: NSViewRepresentable {
    var onDragStart: () -> Void
    var onDrag: (Double) -> Void
    
    func makeNSView(context: Context) -> MouseTrackerView {
        let view = MouseTrackerView()
        view.onDragStart = onDragStart
        view.onDrag = onDrag
        return view
    }
    
    func updateNSView(_ nsView: MouseTrackerView, context: Context) {}
}

class MouseTrackerView: NSView {
    var onDragStart: (() -> Void)?
    var onDrag: ((Double) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .cursorUpdate]
        let newArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(newArea)
        trackingArea = newArea
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        onDragStart?()
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(Double(event.deltaX))
    }

    override func mouseUp(with event: NSEvent) {
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }
}
