//
//  ContentView.swift
//  Volter
//
//  Created by Will on 7/4/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    // GPU cap in watts. 0 = Auto (uncapped). defaultMaxWatts is nil until the first helper read.
    @State private var gpuCap: Double = 0.0
    @State private var baseGpuCap: Double = 0.0
    @State private var defaultMaxWatts: Double? = nil

    @State private var showingSettings = false
    @State private var isApplying = false // Tracking backend execution state
    @State private var hasPendingChanges = false // sticky flag: true after first edit until next Apply (even if you revert sliders)

    /// Chip marketing name, read once (sudoless sysctl, e.g. "M5 Pro").
    private static let chipLabel: String = PowerManager.chipName()

    /// Hard "Max" (100W): reaching 28W on the slider snaps to restore.
    /// Visible track ends at 20W; dragging past it accumulates invisibly to 28W.
    private var sliderMax: Double { PowerManager.snapToMaxWatts }
    private var trackMax: Double { 20.0 }
    private var isAtMax: Bool { gpuCap >= PowerManager.snapToMaxWatts - 0.001 }

    // Diff from last applied config — use for sticky logic
    private var hasChanges: Bool {
        defaultMaxWatts != nil && abs(gpuCap - baseGpuCap) > 0.001
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            
            // 1. Static Header Row: Explicitly sized to 290px to lock all elements in place
            HStack(alignment: .center) {
                // Left Title (Cross-fade transition)
                ZStack(alignment: .leading) {
                    if !showingSettings {
                        Text(Self.chipLabel)
                            .font(.headline)
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
                    .frame(width: 290, height: 40)
                    .disabled(isApplying)
                
                settingsBody
                    .frame(width: 290, height: 40)
            }
            .frame(width: 580, height: 40, alignment: .leading)
            .offset(x: showingSettings ? -290 : 0)
            .offset(y: 38)
        }
        .frame(width: 290, height: 90, alignment: .topLeading)
        .clipped() // Prevents sliding views from rendering outside the window boundaries
        .onChange(of: hasChanges) { _, newValue in
            if newValue { hasPendingChanges = true }
        }
        .onChange(of: gpuCap) { _, _ in if hasChanges { hasPendingChanges = true } }
        .task {
            refreshFromHelper()
        }
    }
    
    // MARK: - Main Panel View
    private var mainBody: some View {
        Group {
            if defaultMaxWatts != nil {
                // GPU cap slider (far left = Auto, far right = Max/restore)
                HStack(alignment: .center) {
                    Text("Power:")
                        .font(.body)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 88, alignment: .leading)

                    CustomTickSlider(value: $gpuCap, range: 0...sliderMax,
                                     physicalMax: trackMax, tickCount: 25, stepSize: 1.0)

                    // Static Readout Label (mirrors the old fan Auto pattern)
                    Text(gpuCap <= 0.001 ? "Auto" : (isAtMax ? "Max" : String(format: "%gW", gpuCap)))
                        .font(.body)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 55, height: 20, alignment: .trailing)
                }
                .frame(height: 24)
                .padding(.horizontal, 16)
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.7)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        }
    }
    
    // MARK: - Settings Panel View
    private var settingsBody: some View {
        VStack(spacing: 8) {
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
    private func refreshFromHelper() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let s = PowerManager.shared.readStatus() else { return }
            DispatchQueue.main.async {
                defaultMaxWatts = s.defaultMaxWatts
                // Live applied cap; Auto (0) when uncapped or capped above our range
                if s.capWatts >= s.defaultMaxWatts - 0.001 || s.capWatts > PowerManager.snapToMaxWatts {
                    gpuCap = 0.0
                } else {
                    gpuCap = s.capWatts
                }
                baseGpuCap = gpuCap
                hasPendingChanges = false
            }
        }
    }

    private func applyChanges() {
        // Prevent concurrent execution queueing
        guard !isApplying else { return }
        guard defaultMaxWatts != nil else { return }
        isApplying = true

        let targetCap = gpuCap

        DispatchQueue.global(qos: .userInitiated).async {
            let status = PowerManager.shared.applyCap(watts: targetCap)

            DispatchQueue.main.async {
                isApplying = false
                if let s = status {
                    // Update baseline targets on success
                    baseGpuCap = targetCap
                    defaultMaxWatts = s.defaultMaxWatts
                    hasPendingChanges = false
                } else {
                    // Roll back working value to previous baseline because execution failed
                    withAnimation(.easeInOut(duration: 0.2)) {
                        gpuCap = baseGpuCap
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
