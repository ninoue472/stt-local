import SwiftUI

struct WaveformView: View {
    let energies: [Float]
    var color: Color = Color(nsColor: .systemGray)

    var body: some View {
        Canvas { context, size in
            guard !energies.isEmpty, size.width > 0, size.height > 0 else { return }

            let samples = resampledEnergies(targetCount: max(28, Int(size.width / 9)))
            let midY = size.height / 2
            let metrics = barMetrics(for: size, count: samples.count)

            for (index, sample) in samples.enumerated() {
                let x = CGFloat(index) * metrics.stepX
                let amplitude = barAmplitude(
                    samples: samples,
                    sample: sample,
                    index: index,
                    maxHeight: size.height * 0.92
                )
                let rect = CGRect(
                    x: x,
                    y: midY - amplitude / 2,
                    width: metrics.barWidth,
                    height: amplitude
                )

                context.fill(
                    Path(roundedRect: rect, cornerRadius: metrics.barWidth / 2),
                    with: .color(color.opacity(0.95))
                )
            }
        }
    }

    private func resampledEnergies(targetCount: Int) -> [CGFloat] {
        guard !energies.isEmpty else { return [] }
        if energies.count == 1 {
            let sample = normalizedEnergy(energies[0])
            return Array(repeating: sample, count: max(targetCount, 1))
        }
        if energies.count == targetCount {
            return energies.map(normalizedEnergy)
        }

        return (0..<targetCount).map { index in
            let position = CGFloat(index) / CGFloat(max(targetCount - 1, 1))
            let sourceIndex = position * CGFloat(energies.count - 1)
            let lower = min(Int(sourceIndex.rounded(.down)), energies.count - 1)
            let upper = min(lower + 1, energies.count - 1)
            let fraction = sourceIndex - CGFloat(lower)
            let blended = CGFloat(energies[lower]) * (1 - fraction) + CGFloat(energies[upper]) * fraction
            return normalizedEnergy(Float(blended))
        }
    }

    private func normalizedEnergy(_ value: Float) -> CGFloat {
        let clamped = max(0, min(value, 1))
        return max(0.06, pow(CGFloat(clamped), 0.82))
    }

    private func barMetrics(for size: CGSize, count: Int) -> (stepX: CGFloat, barWidth: CGFloat) {
        let stepX = size.width / CGFloat(max(count, 1))
        let barWidth = min(5.5, max(3.0, stepX * 0.54))
        return (stepX, barWidth)
    }

    private func barAmplitude(samples: [CGFloat], sample: CGFloat, index: Int, maxHeight: CGFloat) -> CGFloat {
        let previous = index > 0 ? samples[index - 1] : sample
        let next = index + 1 < samples.count ? samples[index + 1] : sample
        let smoothed = (previous * 0.22) + (sample * 0.56) + (next * 0.22)
        let position = CGFloat(index) / CGFloat(max(samples.count - 1, 1))
        let taper = 0.55 + 0.45 * sin(position * .pi)
        return max(6, maxHeight * smoothed * taper)
    }
}
