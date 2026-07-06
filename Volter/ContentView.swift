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
            
            // Row 3: Power Limit (Clamped at 43W maximum)
            HStack(alignment: .center) {
                Text("Power Limit:")
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                
                CustomTickSlider(value: Binding(
                    get: { min(powerLimit, 43.0) },
                    set: { powerLimit = $0 }
                ), range: 0...43)
                
                // Static Readout Label (Drag-to-adjust removed)
                Text(Int(powerLimit) == 0 ? "Off" : "\(Int(powerLimit))W")
                    .font(.body)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 45, height: 20, alignment: .trailing)
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
    let physicalMax: Double = 24.0 // Visually maxes out at 24W
    let tickCount: Int = 25        // 0 to 24 visual markers

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbWidth: CGFloat = 14
            let usableWidth = width - thumbWidth
            
            // Constrain the visual thumb's layout alignment to 0...24 range
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
                .offset(x: thumbWidth / 2, y: -6)
                
                // 2. The Non-Blue Slider Bar (Solid grey track directly below indicators)
                Capsule()
                    .fill(Color(NSColor.separatorColor).opacity(0.75))
                    .frame(width: usableWidth, height: 3)
                    .offset(x: thumbWidth / 2, y: 3)
                
                // 3. The Pentagon Thumb (Situated on the track, tip points up to the ticks)
                PointingUpThumbShape()
                    .fill(Color.white)
                    .overlay(
                        PointingUpThumbShape()
                            .stroke(Color.gray.opacity(0.42), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    )
                    .shadow(color: Color.black.opacity(0.14), radius: 1, x: 0, y: 1)
                    .frame(width: thumbWidth, height: 14)
                    .offset(x: thumbCenterX - (thumbWidth / 2), y: 8)
            }
            // Explicitly aligned to leading boundary to match geometry coordinates perfectly
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gestureValue in
                        let stepWidth = usableWidth / physicalMax
                        let locationX = gestureValue.location.x - (thumbWidth / 2)
                        
                        let calculatedValue: Double
                        if locationX <= usableWidth {
                            // Dragging inside visible bounds: 0...24W
                            let rawPercent = max(0, locationX) / usableWidth
                            calculatedValue = Double(rawPercent) * physicalMax
                        } else {
                            // Dragging past the right boundary: continues accumulating steps up to 43W
                            let extraWidth = locationX - usableWidth
                            let extraSteps = extraWidth / stepWidth
                            calculatedValue = physicalMax + Double(extraSteps)
                        }
                        
                        // Bounds clamped strictly at 43W maximum
                        value = min(max(round(calculatedValue), range.lowerBound), range.upperBound)
                    }
            )
        }
        .frame(height: 20)
    }
}
