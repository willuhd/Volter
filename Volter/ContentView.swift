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
    @State private var isApplying = false // Tracking backend execution state
    
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
        ZStack(alignment: .topLeading) {
            
            // 1. Static Header Row: Explicitly sized to 290px to lock all elements in place
            HStack(alignment: .center) {
                // Left Title / Checkbox (Cross-fade transition)
                ZStack(alignment: .leading) {
                    if !showingSettings {
                        Toggle("Turbo", isOn: $turbo)
                            .toggleStyle(.checkbox)
                            .font(.body)
                            .disabled(isApplying)
                            .transition(.opacity)
                    } else {
                        Text("Volter")
                            .font(.system(size: 16, weight: .bold))
                            .transition(.opacity)
                    }
                }
                
                Spacer()
                
                // Right static alignment container (Anchored to prevent shifting)
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
                        .disabled(isApplying)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    
                    // Checkmark Button: Anchored firmly (never moves vertically or horizontally)
                    Button(action: {
                        if showingSettings {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showingSettings = false
                            }
                        } else {
                            applyChanges()
                        }
                    }) {
                        ZStack {
                            if isApplying {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.5)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(showingSettings ? .secondary : (hasChanges ? .white : .secondary))
                                    .frame(width: 20, height: 20)
                                    .background(showingSettings ? Color(NSColor.controlColor) : (hasChanges ? Color.blue : Color(NSColor.controlColor)))
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplying || (!hasChanges && !showingSettings))
                }
            }
            .padding(.horizontal, 16)
            .frame(width: 290, height: 24)
            .padding(.top, 12)
            
            // 2. Sliding Body Container (Centered vertically within the remaining frame)
            HStack(spacing: 0) {
                mainBody
                    .frame(width: 290, height: 64)
                    .disabled(isApplying)
                
                settingsBody
                    .frame(width: 290, height: 64)
            }
            .frame(width: 580, height: 64, alignment: .leading)
            .offset(x: showingSettings ? -290 : 0)
            .offset(y: 38)
        }
        .frame(width: 290, height: 114, alignment: .topLeading) // Overall height reduced to 114pt
        .clipped() // Prevents sliding views from rendering outside the window boundaries
    }
    
    // MARK: - Main Panel View
    private var mainBody: some View {
        VStack(spacing: 8) {
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
                            dragPowerAccumulator = min(max(newAccumulator, 0), 24)
                            powerLimit = round(dragPowerAccumulator)
                        }
                    )
                    .frame(width: 45, height: 20)
                }
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 16)
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
        .padding(.horizontal, 16)
    }
    
    // MARK: - Controller Actions
    private func applyChanges() {
        // Prevent concurrent execution queueing
        guard !isApplying else { return }
        isApplying = true
        
        let targetTurbo = turbo
        let targetPowerLimit = powerLimit
        let targetLowPowerMode = lowPowerMode
        
        DispatchQueue.global(qos: .userInitiated).async {
            let success = PowerManager.shared.applySettings(
                turbo: targetTurbo,
                powerLimit: targetPowerLimit,
                lowPowerMode: targetLowPowerMode
            )
            
            DispatchQueue.main.async {
                isApplying = false
                if success {
                    // Update baseline targets on authorization success
                    baseTurbo = targetTurbo
                    basePowerLimit = targetPowerLimit
                    baseLowPowerMode = targetLowPowerMode
                } else {
                    // Roll back working values to previous baseline because execution failed
                    withAnimation(.easeInOut(duration: 0.2)) {
                        turbo = baseTurbo
                        powerLimit = basePowerLimit
                        lowPowerMode = baseLowPowerMode
                    }
                }
            }
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

// MARK: - Custom Tick Slider
struct CustomTickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tickCount: Int = 25

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbWidth: CGFloat = 11
            let usableWidth = width - thumbWidth
            
            let percentage = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbX = percentage * usableWidth + (thumbWidth / 2)
            
            ZStack {
                // Ticks: Styled to align directly with track spacing
                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { i in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 1, height: 5)
                        if i < (tickCount - 1) {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, thumbWidth / 2)
                .offset(y: -7)
                
                // Track: Sleek 2pt height segment
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 2)
                    .padding(.horizontal, thumbWidth / 2)
                
                // Thumb: Sharp, pointing-up pentagonal arrow
                PointingUpThumbShape()
                    .fill(Color.white)
                    .overlay(
                        PointingUpThumbShape()
                            .stroke(Color.gray.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: thumbWidth, height: 11)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                    .offset(x: thumbX - (width / 2), y: 3.5)
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
