import Foundation
import Testing
@testable import PrimuseKit

/// 全屏「果蝇听歌」：包里那份真实听觉通路能读出来，相机投影正确，信号沿接线往里传。
struct FlyAuditoryCircuitTests {
    private func circuit() throws -> FlyAuditoryCircuit {
        try #require(FlyAuditoryCircuit.bundled())
    }

    @Test func bundledCircuitDecodesWithBothEarsAndDeeperLayers() throws {
        let circuit = try circuit()
        #expect(circuit.neurons.count > 300)
        #expect(circuit.edges.count > 1000)
        #expect(circuit.synapses.count > 500)
        #expect(circuit.outlines.count > 50)
        #expect(circuit.outlines.contains { $0.isAuditory })
        let inputs = circuit.neurons.filter { $0.role == .lowFrequencyInput || $0.role == .highFrequencyInput }
        #expect(inputs.count > 100)
        #expect(inputs.allSatisfy { $0.layer == 0 })
        #expect(circuit.neurons.contains { $0.role == .highFrequencyInput })
        #expect(circuit.neurons.contains { $0.role == .descending })
        #expect(Set(circuit.neurons.map(\.layer)) == [0, 1, 2, 3, 4])
        // 两只触角都在：入口神经元左右两边都有。
        let inputX = inputs.compactMap { neuron -> Float? in
            guard let line = neuron.polylines.first else { return nil }
            return circuit.neuronPoints[circuit.polylines[line].lowerBound].x
        }
        #expect(inputX.contains { $0 < -0.05 } && inputX.contains { $0 > 0.05 })
        #expect(circuit.labels.map(\.name).contains("AMMC(L)"))
        #expect(circuit.micrometersPerUnit > 300 && circuit.micrometersPerUnit < 400)
    }

    @Test func geometryIsNormalizedAndIndexedConsistently() throws {
        let circuit = try circuit()
        for point in circuit.outlinePoints + circuit.neuronPoints {
            #expect(abs(point.x) <= 1 && abs(point.y) <= 1 && abs(point.z) <= 1)
        }
        #expect(circuit.neuronPoints.count == circuit.neuronPointDistance.count)
        #expect(circuit.neuronPointDistance.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(circuit.polylines.count == circuit.polylineNeuron.count)
        for (index, neuron) in circuit.neurons.enumerated() {
            for line in neuron.polylines {
                #expect(circuit.polylineNeuron[line] == index)
                #expect(circuit.polylines[line].count >= 2)
            }
        }
        for index in 1..<circuit.edges.count {
            #expect(circuit.edges[index - 1].pre <= circuit.edges[index].pre)
        }
        for index in 1..<circuit.synapses.count {
            #expect(circuit.synapses[index - 1].pre <= circuit.synapses[index].pre)
        }
    }

    @Test func malformedDataIsRejected() {
        #expect(throws: FlyAuditoryCircuit.DecodeError.badHeader) {
            try FlyAuditoryCircuit.decode(Data("NOPE".utf8))
        }
        var header = Data("PMFC".utf8)
        header.append(contentsOf: [1, 0, 0, 0])
        #expect(throws: FlyAuditoryCircuit.DecodeError.truncated) {
            try FlyAuditoryCircuit.decode(header)
        }
    }

    @Test func cameraKeepsTheCenterAndEnlargesNearPoints() {
        let front = FlyBrainCamera(yaw: 0, pitch: 0)
        #expect(front.project(SIMD3(0, 0, 0)) == SIMD3(0, 0, 1))
        let near = front.project(SIMD3(0.5, 0, -0.5))
        let far = front.project(SIMD3(0.5, 0, 0.5))
        #expect(near.x > far.x)
        #expect(near.z > 1 && far.z < 1)
        // 绕竖轴转 90°：原来在后面的点转到右边。
        let turned = FlyBrainCamera(yaw: .pi / 2, pitch: 0).project(SIMD3(0, 0, 0.5))
        #expect(turned.x > 0.4)
        var batch: [SIMD2<Float>] = []
        let points: [SIMD3<Float>] = [SIMD3(0.2, -0.3, 0.1), SIMD3(-0.6, 0.4, -0.2)]
        let camera = FlyBrainCamera.resting
        camera.project(points, into: &batch)
        for (index, point) in points.enumerated() {
            let single = camera.project(point)
            #expect(abs(batch[index].x - single.x) < 1e-6 && abs(batch[index].y - single.y) < 1e-6)
        }
        let orbit = FlyBrainCamera.orbit(at: 12.5)
        #expect(abs(orbit.yaw) <= 0.45 && orbit.pitch >= 0.17 && orbit.pitch <= 0.29)
    }

    private func meanActivation(_ simulation: FlyAuditorySimulation, _ circuit: FlyAuditoryCircuit, where include: (FlyAuditoryCircuit.Neuron) -> Bool) -> Float {
        let values = circuit.neurons.indices.filter { include(circuit.neurons[$0]) }.map { simulation.activation[$0] }
        return values.reduce(0, +) / Float(max(values.count, 1))
    }

    @Test func lowNotesWakeTheLowFrequencyEarFirst() throws {
        let circuit = try circuit()
        var simulation = FlyAuditorySimulation(circuit: circuit)
        let bass = (0..<32).map { $0 < 6 ? 0.9 : 0.05 }
        for _ in 0..<15 { simulation.step(dt: 1.0 / 30, levels: bass, beat: 0) }
        let low = meanActivation(simulation, circuit) { $0.role == .lowFrequencyInput }
        let high = meanActivation(simulation, circuit) { $0.role == .highFrequencyInput }
        #expect(low > 0.5)
        #expect(high < low * 0.5)
    }

    @Test func soundTravelsInwardLayerByLayerAndSilenceCalmsIt() throws {
        let circuit = try circuit()
        var simulation = FlyAuditorySimulation(circuit: circuit)
        // 每半秒一记鼓：入口神经元对「比刚才更响」起反应，一直响着的音会被适应掉。
        func drum(_ step: Int) -> [Double] {
            let hit = step % 15 < 2
            return (0..<32).map { $0 < 16 ? (hit ? 0.95 : 0.35) : 0.3 }
        }
        var firstSpikeTime = [Int: TimeInterval]()
        var seenDeepSpike = false
        var peak: Float = 0
        for step in 0..<90 {
            simulation.step(dt: 1.0 / 30, levels: drum(step), beat: step % 15 == 0 ? 0.8 : 0)
            peak = max(peak, meanActivation(simulation, circuit) { $0.layer > 0 })
            for spike in simulation.spikes {
                let layer = circuit.neurons[spike.neuron].layer
                if firstSpikeTime[layer] == nil { firstSpikeTime[layer] = spike.start }
                if layer >= 2 { seenDeepSpike = true }
            }
            #expect(simulation.spikes.count <= FlyAuditorySimulation.maximumSpikes)
        }
        #expect(seenDeepSpike)
        // 入口先放电，往里的层晚一点。
        if let input = firstSpikeTime[0], let second = firstSpikeTime[2] {
            #expect(input < second)
        }
        #expect(peak > 0.05)

        for _ in 0..<(30 * 4) {
            simulation.step(dt: 1.0 / 30, levels: Array(repeating: 0, count: 32), beat: 0)
        }
        #expect(meanActivation(simulation, circuit) { $0.layer > 0 } < peak * 0.2)
        if let spike = simulation.spikes.last {
            #expect(simulation.front(of: spike) >= 0)
        }
    }
}

extension FlyAuditoryCircuitTests {
    @Test func pointCloudProjectsLikeTheCamera() throws {
        let points: [SIMD3<Float>] = [SIMD3(0.4, -0.2, 0.1), SIMD3(-0.9, 0.5, -0.6), SIMD3(0, 0, 0), SIMD3(0.2, 0.7, 0.9)]
        let cloud = FlyBrainPointCloud(points)
        for camera in [FlyBrainCamera.resting, FlyBrainCamera.orbit(at: 13), FlyBrainCamera(yaw: -0.4, pitch: 0.3, distance: 2.5)] {
            var flat: [Float] = []
            cloud.project(with: camera, into: &flat)
            #expect(flat.count == points.count * 2)
            for (index, point) in points.enumerated() {
                let expected = camera.project(point)
                #expect(abs(flat[2 * index] - expected.x) < 1e-5)
                #expect(abs(flat[2 * index + 1] - expected.y) < 1e-5)
            }
        }
        var empty: [Float] = [1, 2]
        FlyBrainPointCloud([]).project(with: .resting, into: &empty)
        #expect(empty.isEmpty)
    }
}
