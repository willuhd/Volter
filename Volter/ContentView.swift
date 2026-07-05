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

    let modes = ["Off", "On", "Battery"]

    // Computed property to detect state divergence
    var hasChanges: Bool {
        turbo != baseTurbo ||
        lowPowerMode != baseLowPowerMode ||
        Int(powerLimit) != Int(basePowerLimit)
    }

    var body: some View {
        VStack(spacing: 12) {
            
            // Header Row: Locked vertical structure for zero pixel shift during transition
            HStack(alignment: .center) {
                // Left Title / Checkbox
                ZStack(alignment: .leading) {
                    if !showingSettings {
                        Toggle("Turbo", isOn: $turbo)
                            .toggleStyle(.checkbox)
                            .font(.body)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .leading)),
                                removal: .opacity.combined(with: .move(edge: .leading))
                            ))
                    } else {
                        Text("Volter")
                            .font(.system(size: 16, weight: .bold))
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .leading)),
                                removal: .opacity.combined(with: .move(edge: .leading))
                            ))
                    }
                }
                
                Spacer()

                // Right static alignment container
                HStack(spacing: 8) {
                    if !showingSettings {
                        Group {
                            if hasChanges {
                                // Cancel Button
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        turbo = baseTurbo
                                        lowPowerMode = baseLowPowerMode
                                        powerLimit = basePowerLimit
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.primary)
                                        .frame(width: 20, height: 20)
                                        .background(Color(NSColor.controlColor))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            } else {
                                // Settings Button
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.22)) {
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
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                    }

                    // Checkmark Button: Anchored firmly (does not move or bounce)
                    Button(action: {
                        if showingSettings {
                            withAnimation(.easeInOut(duration: 0.22)) {
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
            .frame(height: 22)

            // Dynamic Body Content Area
            ZStack {
                if !showingSettings {
                    VStack(spacing: 12) {
                        // Row 2: Low Power Mode (Dynamically stretches picker to fill space)
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

                        // Row 3: Power Limit (Slider centered and scaled with step behaviors)
                        HStack(alignment: .center) {
                            Text("Power Limit:")
                                .font(.body)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            CustomTickSlider(value: Binding(
                                get: { min(powerLimit, 24.0) },
                                set: { powerLimit = $0 }
                            ), range: 0...24)

                            // Readout Label (Background-free styling)
                            ZStack {
                                Text(Int(powerLimit) == 0 ? "Off" : "\(Int(powerLimit))W")
                                    .font(.body)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 45, height: 20, alignment: .trailing)
                                
                                RelativeDragTracker { deltaX in
                                    let calculatedValue = powerLimit + (deltaX / 5.0)
                                    // Limit values strictly to whole integer steps when dragged
                                    powerLimit = min(max(round(calculatedValue), 0), 45)
                                }
                                .frame(width: 45, height: 20)
                            }
                        }
                        .frame(height: 22)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))
                } else {
                    // Settings Panel
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
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 290, height: 125)
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

// MARK: - Custom Tick Slider (With Centered Alignment & Value Snapping)
struct CustomTickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tickCount: Int = 25 // Represents discrete integers 0 to 24

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbWidth: CGFloat = 11
            let usableWidth = width - thumbWidth
            
            let percentage = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbX = percentage * usableWidth + (thumbWidth / 2)
            
            ZStack {
                // 1. Tick Marks (Positioned above the center track line)
                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { i in
                        Rectangle()
                            .fill(Color.gray.opacity(0.35))
                            .frame(width: 1, height: 5)
                        if i < (tickCount - 1) {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, thumbWidth / 2)
                .offset(y: -5)
                
                // 2. Track (Positioned centrally)
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 1.5)
                    .padding(.horizontal, thumbWidth / 2)
                
                // 3. Thumb Shape (Aligned to slide cleanly over centered track)
                PointingUpThumbShape()
                    .fill(Color.white)
                    .overlay(
                        PointingUpThumbShape()
                            .stroke(Color.gray.opacity(0.6), lineWidth: 1)
                    )
                    .frame(width: thumbWidth, height: 11)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                    .offset(x: thumbX - (width / 2), y: 3)
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

// MARK: - Cocoa Relative Mouse Movement Capture
struct RelativeDragTracker: NSViewRepresentable {
    var onDrag: (Double) -> Void
    
    func makeNSView(context: Context) -> MouseTrackerView {
        let view = MouseTrackerView()
        view.onDrag = onDrag
        return view
    }
    
    func updateNSView(_ nsView: MouseTrackerView, context: Context) {}
}

class MouseTrackerView: NSView {
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
        // Halt physical cursor layout modifications
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(Double(event.deltaX))
    }

    override func mouseUp(with event: NSEvent) {
        // Restore physical cursor tracking
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }
}
