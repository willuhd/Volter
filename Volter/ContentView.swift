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
    @State private var fanSpeed: Double = 0
    
    // Baseline states to track rollback targets
    @State private var baseTurbo = false
    @State private var baseLowPowerMode = "Off"
    @State private var basePowerLimit: Double = 14.0
    @State private var baseFanSpeed: Double = 0
    
    @State private var showingSettings = false
    @State private var isApplying = false // Tracking backend execution state
    @State private var hasPendingChanges = false // sticky flag: true after first edit until next Apply (even if you revert sliders)
    
    let modes = ["Off", "On", "Battery"]
    
    // Diff from last applied config — use for sticky logic
    private var hasChanges: Bool {
        turbo != baseTurbo ||
        lowPowerMode != baseLowPowerMode ||
        abs(powerLimit - basePowerLimit) > 0.001 ||
        abs(fanSpeed - baseFanSpeed) > 0.001
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
                
                // Single top-right button: gear <-> blue check (settings only when no pending changes)
                Button(action: {
                    if showingSettings {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingSettings = false
                        }
                    } else if hasPendingChanges {
                        applyChanges()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingSettings = true
                        }
                    }
                }) {
                    ZStack {
                        if isApplying {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.5)
                                .frame(width: 20, height: 20)
                        } else if showingSettings {
                            // Close settings
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                                .background(Color(NSColor.controlColor))
                                .clipShape(Circle())
                        } else if hasPendingChanges {
                            // Pending confirm — blue
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.blue)
                                .clipShape(Circle())
                        } else {
                            // Idle — settings gear
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.primary)
                                .frame(width: 20, height: 20)
                                .background(Color(NSColor.controlColor))
                                .clipShape(Circle())
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
                .animation(.easeInOut(duration: 0.2), value: hasPendingChanges)
                .animation(.easeInOut(duration: 0.25), value: showingSettings)
            }
            .padding(.horizontal, 16)
            .frame(width: 290, height: 24)
            .padding(.top, 12)
            
            // 2. Sliding Body Container (Centered vertically within the remaining frame)
            HStack(spacing: 0) {
                mainBody
                    .frame(width: 290, height: 96)
                    .disabled(isApplying)
                
                settingsBody
                    .frame(width: 290, height: 96)
            }
            .frame(width: 580, height: 96, alignment: .leading)
            .offset(x: showingSettings ? -290 : 0)
            .offset(y: 38)
        }
        .frame(width: 290, height: 146, alignment: .topLeading)
        .clipped() // Prevents sliding views from rendering outside the window boundaries
        .onChange(of: hasChanges) { _, newValue in
            if newValue { hasPendingChanges = true }
        }
        // Also catch slider drags that may not trigger hasChanges immediately due to floating rounding
        .onChange(of: turbo) { _, _ in if hasChanges { hasPendingChanges = true } }
        .onChange(of: lowPowerMode) { _, _ in if hasChanges { hasPendingChanges = true } }
        .onChange(of: powerLimit) { _, _ in if hasChanges { hasPendingChanges = true } }
        .onChange(of: fanSpeed) { _, _ in if hasChanges { hasPendingChanges = true } }
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
            
            // Row 3: Power Limit (Clamped at 43W maximum)
            HStack(alignment: .center) {
                Text("Power Limit:")
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 88, alignment: .leading)
                
                CustomTickSlider(value: Binding(
                    get: { min(powerLimit, 43.0) },
                    set: { powerLimit = $0 }
                ), range: 0...43)
                
                // Static Readout Label
                Text(Int(powerLimit) == 0 ? "Off" : "\(Int(powerLimit))W")
                    .font(.body)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 45, height: 20, alignment: .trailing)
            }
            .frame(height: 24)
            
            // Row 4: Fan Speed (Clamped at 9000 RPM maximum)
            HStack(alignment: .center) {
                Text("Fan Speed:")
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 88, alignment: .leading)
                
                CustomTickSlider(value: Binding(
                    get: { min(fanSpeed, 9000.0) },
                    set: { fanSpeed = $0 }
                ), range: 0...9000, physicalMax: 7200, tickCount: 25, stepSize: 300)
                
                // Static Readout Label
                Text(Int(fanSpeed) == 0 ? "Auto" : "\(Int(fanSpeed))")
                    .font(.body)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 45, height: 20, alignment: .trailing)
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 16)
    }
    
    // MARK: - Settings Panel View
    private var settingsBody: some View {
        VStack(spacing: 8) {
            Spacer()
            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://github.com/willuhd/Volter")!)
            }) {
                Text("Browse the source code")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(Color(NSColor.controlColor))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
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
        let targetFanSpeed = fanSpeed
        
        DispatchQueue.global(qos: .userInitiated).async {
            let success = PowerManager.shared.applySettings(
                turbo: targetTurbo,
                powerLimit: targetPowerLimit,
                lowPowerMode: targetLowPowerMode,
                fanSpeed: targetFanSpeed
            )
            
            DispatchQueue.main.async {
                isApplying = false
                if success {
                    // Update baseline targets on authorization success
                    baseTurbo = targetTurbo
                    basePowerLimit = targetPowerLimit
                    baseLowPowerMode = targetLowPowerMode
                    baseFanSpeed = targetFanSpeed
                    hasPendingChanges = false
                } else {
                    // Roll back working values to previous baseline because execution failed
                    withAnimation(.easeInOut(duration: 0.2)) {
                        turbo = baseTurbo
                        powerLimit = basePowerLimit
                        lowPowerMode = baseLowPowerMode
                        fanSpeed = baseFanSpeed
                    }
                    hasPendingChanges = false
                }
            }
        }
    }
}

// MARK: - Pointing-Up Pentagon Thumb Shape (Rounded corner design matching image)
struct PointingUpThumbShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 2.0 // Subtle rounding factor for the corners/shoulders
        
        // Starts drawing from the bottom-left corner with rounding
        path.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        
        // Rises up the right vertical edge to the rounded shoulder
        let shoulderY = rect.height * 0.44
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulderY + r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: shoulderY),
                          control: CGPoint(x: rect.maxX, y: shoulderY + r/2))
        
        // Converges upward to the pointing tip
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        
        // Descends to the left rounded shoulder
        path.addLine(to: CGPoint(x: rect.minX + r, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: shoulderY + r),
                          control: CGPoint(x: rect.minX, y: shoulderY + r/2))
        
        // Descends the left vertical edge back down to the bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        
        path.closeSubpath()
        return path
    }
}

// MARK: - Custom Tick Slider
struct CustomTickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var physicalMax: Double = 24.0 // Visually maxes out at this value
    var tickCount: Int = 25        // Number of visual tick markers
    var stepSize: Double = 1.0     // Snap interval for value rounding

    @State private var isDragging: Bool = false // Tracks active selection state

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbWidth: CGFloat = 14
            let usableWidth = width - thumbWidth
            
            // Constrain the visual thumb's layout alignment to physicalMax range
            let clampedVisualValue = min(value, physicalMax)
            let percentage = CGFloat(clampedVisualValue / physicalMax)
            let thumbCenterX = (percentage * usableWidth) + (thumbWidth / 2)
            
            ZStack(alignment: .leading) {
                // 1. Indicators (Ticks) positioned on top of the bar
                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { i in
                        Rectangle()
                            .fill(Color(NSColor.placeholderTextColor).opacity(0.45))
                            .frame(width: 1, height: 5)
                        if i < (tickCount - 1) {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(width: usableWidth)
                .offset(x: thumbWidth / 2, y: -3)
                
                // 2. The Non-Blue Slider Bar (Solid grey track directly below indicators)
                Capsule()
                    .fill(Color(NSColor.separatorColor).opacity(0.75))
                    .frame(width: usableWidth, height: 3)
                    .offset(x: thumbWidth / 2, y: 7)
                
                // 3. The Pentagon Thumb (Overlaps track, pointing tip aligns with ticks)
                PointingUpThumbShape()
                    .fill(Color.white)
                    .overlay(
                        PointingUpThumbShape()
                            .stroke(
                                Color.gray.opacity(0.42),
                                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                            )
                    )
                    .shadow(color: Color.black.opacity(0.14), radius: 1, x: 0, y: 1)
                    .frame(width: thumbWidth, height: 14)
                    // The transparency dimming is applied directly here to only affect the pentagon
                    .opacity(isDragging ? 0.65 : 1.0)
                    .offset(x: thumbCenterX - (thumbWidth / 2), y: 4)
            }
            // Explicitly aligned to leading boundary to match geometry coordinates perfectly
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gestureValue in
                        isDragging = true
                        
                        let stepWidth = usableWidth / (physicalMax / stepSize)
                        let locationX = gestureValue.location.x - (thumbWidth / 2)
                        
                        let calculatedValue: Double
                        if locationX <= usableWidth {
                            // Dragging inside visible bounds: 0...physicalMax
                            let rawPercent = max(0, locationX) / usableWidth
                            calculatedValue = Double(rawPercent) * physicalMax
                        } else {
                            // Dragging past the right boundary: continues accumulating steps up to range max
                            let extraWidth = locationX - usableWidth
                            let extraSteps = extraWidth / stepWidth
                            calculatedValue = physicalMax + Double(extraSteps) * stepSize
                        }
                        
                        // Snap to step interval and clamp to range
                        let snapped = (calculatedValue / stepSize).rounded() * stepSize
                        value = min(max(snapped, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 24) // Frame height completely wraps visual range for reliable hit-testing
    }
}
