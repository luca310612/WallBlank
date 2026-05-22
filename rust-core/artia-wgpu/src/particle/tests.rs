// Phase 4A: ParticleSystem CPU シミュレーションのユニットテスト
// Why: GPU compute kernel との等価ロジックを Rust 側でロックし、
//      Initializer / Operator / Emitter の挙動を決定論的に検証する。

use super::*;

fn snow_system() -> ParticleSystem {
    // 上部から雪が降る最小構成。
    let descriptor = ParticleSystemDescriptor {
        capacity: 32,
        seed: 0xDEAD_BEEF,
        emitter: EmitterDescriptor {
            origin: [50.0, 100.0],
            spawn_rate: 10.0, // 10 個 / 秒
            burst: 0,
            shape: EmitterShape::Point,
        },
        initializers: vec![
            InitializerDescriptor::LifetimeRange { min: 1.0, max: 1.0 },
            InitializerDescriptor::ColorRamp { color: [1.0, 1.0, 1.0, 1.0] },
            InitializerDescriptor::SizeRange { min: 2.0, max: 4.0 },
            InitializerDescriptor::VelocityCone {
                direction: [0.0, -1.0],
                angle: 0.0,
                speed_min: 30.0,
                speed_max: 30.0,
            },
        ],
        operators: vec![OperatorDescriptor::Gravity {
            acceleration: [0.0, -10.0],
        }],
    };
    ParticleSystem::new(ParticleSystemId(1), descriptor)
}

#[test]
fn simulate_one_step_emits_particles() {
    let mut sys = snow_system();
    // 0.1 秒で spawn_rate=10 → 1 個出るはず
    sys.simulate_cpu(0.1);
    assert_eq!(sys.last_spawn_count, 1, "1 ステップで 1 個 spawn されるはず");
    assert_eq!(sys.alive_count(), 1, "spawn されたものが alive 1 個");
}

#[test]
fn burst_emits_immediately() {
    let mut descriptor = ParticleSystemDescriptor {
        capacity: 16,
        seed: 1,
        emitter: EmitterDescriptor {
            origin: [0.0, 0.0],
            spawn_rate: 0.0,
            burst: 8,
            shape: EmitterShape::Point,
        },
        initializers: vec![InitializerDescriptor::LifetimeRange { min: 1.0, max: 1.0 }],
        operators: vec![],
    };
    descriptor.capacity = 16;
    let mut sys = ParticleSystem::new(ParticleSystemId(1), descriptor);
    sys.simulate_cpu(0.016);
    assert_eq!(sys.last_spawn_count, 8, "burst=8 が一括で出る");
    assert_eq!(sys.alive_count(), 8);
    // 2 ステップ目では burst が消費済みなので新規 spawn されない
    sys.simulate_cpu(0.016);
    assert_eq!(sys.last_spawn_count, 0, "burst は 1 度だけ");
}

#[test]
fn gravity_operator_accelerates_particle() {
    // 単発 burst で 1 個出してから重力を見る
    let descriptor = ParticleSystemDescriptor {
        capacity: 4,
        seed: 1,
        emitter: EmitterDescriptor {
            origin: [0.0, 0.0],
            spawn_rate: 0.0,
            burst: 1,
            shape: EmitterShape::Point,
        },
        initializers: vec![
            InitializerDescriptor::LifetimeRange { min: 5.0, max: 5.0 },
            InitializerDescriptor::VelocityCone {
                direction: [1.0, 0.0],
                angle: 0.0,
                speed_min: 0.0,
                speed_max: 0.0, // 初速 0
            },
        ],
        operators: vec![OperatorDescriptor::Gravity { acceleration: [0.0, -100.0] }],
    };
    let mut sys = ParticleSystem::new(ParticleSystemId(1), descriptor);
    // ステップ 1: spawn のみ (1 ステップ前は速度 0)
    sys.simulate_cpu(0.1);
    let v_after_first = sys.particles[0].velocity[1];
    assert!(v_after_first <= 0.0, "重力で y 速度が下方向に積まれているはず");
    let p1 = sys.particles[0].position[1];
    sys.simulate_cpu(0.1);
    let p2 = sys.particles[0].position[1];
    assert!(p2 < p1, "次フレームで y 座標が更に下がる");
}

#[test]
fn kill_beyond_bounds_removes_particle() {
    let descriptor = ParticleSystemDescriptor {
        capacity: 2,
        seed: 1,
        emitter: EmitterDescriptor {
            origin: [0.0, 0.0],
            spawn_rate: 0.0,
            burst: 1,
            shape: EmitterShape::Point,
        },
        initializers: vec![
            InitializerDescriptor::LifetimeRange { min: 100.0, max: 100.0 },
            InitializerDescriptor::VelocityCone {
                direction: [1.0, 0.0],
                angle: 0.0,
                speed_min: 200.0,
                speed_max: 200.0,
            },
        ],
        operators: vec![OperatorDescriptor::KillBeyondBounds {
            min: [-10.0, -10.0],
            max: [10.0, 10.0],
        }],
    };
    let mut sys = ParticleSystem::new(ParticleSystemId(1), descriptor);
    // ステップ 1: burst で 1 個出る (位置 (0,0), 速度 (200,0))。spawn は frame 末に行われるため、
    // この時点では位置/速度の更新も走らず範囲内のまま。
    sys.simulate_cpu(0.1);
    assert_eq!(sys.alive_count(), 1, "ステップ 1 ではまだ生存");
    // ステップ 2: 速度 200x で 0.1 秒積分 → 位置が (20, 0) に到達 (範囲 max=10 を超過)。
    //             まだ KillBeyondBounds 評価のタイミング上 alive。
    sys.simulate_cpu(0.1);
    // ステップ 3: 改めて KillBeyondBounds が範囲外を検出 → alive 0 になる。
    sys.simulate_cpu(0.0001);
    assert_eq!(sys.alive_count(), 0, "範囲外 kill で alive 0 になる");
    assert_eq!(sys.last_kill_count, 1);
}

#[test]
fn size_over_life_interpolates_size() {
    let descriptor = ParticleSystemDescriptor {
        capacity: 1,
        seed: 1,
        emitter: EmitterDescriptor {
            origin: [0.0, 0.0],
            spawn_rate: 0.0,
            burst: 1,
            shape: EmitterShape::Point,
        },
        initializers: vec![
            InitializerDescriptor::LifetimeRange { min: 1.0, max: 1.0 },
            InitializerDescriptor::SizeRange { min: 10.0, max: 10.0 },
        ],
        operators: vec![OperatorDescriptor::SizeOverLife { start: 10.0, end: 0.0 }],
    };
    let mut sys = ParticleSystem::new(ParticleSystemId(1), descriptor);
    sys.simulate_cpu(0.0001); // spawn
    let s0 = sys.particles[0].size;
    // 寿命の半分付近まで進める
    sys.simulate_cpu(0.5);
    let s1 = sys.particles[0].size;
    assert!(s1 < s0, "寿命進行で size が減少するはず: {} -> {}", s0, s1);
    assert!((0.0..10.0).contains(&s1));
}

#[test]
fn descriptor_round_trips_via_json() {
    let descriptor = ParticleSystemDescriptor {
        capacity: 1024,
        seed: 42,
        emitter: EmitterDescriptor {
            origin: [10.0, 20.0],
            spawn_rate: 5.0,
            burst: 0,
            shape: EmitterShape::Circle { radius: 50.0 },
        },
        initializers: vec![InitializerDescriptor::LifetimeRange { min: 0.5, max: 1.5 }],
        operators: vec![OperatorDescriptor::Gravity {
            acceleration: [0.0, -9.8],
        }],
    };
    let json = serde_json::to_string(&descriptor).unwrap();
    let back: ParticleSystemDescriptor = serde_json::from_str(&json).unwrap();
    assert_eq!(descriptor, back);
}

#[test]
fn update_params_replaces_operators() {
    let mut sys = snow_system();
    let new_ops = vec![OperatorDescriptor::Drag { coefficient: 0.5 }];
    sys.apply_params(ParticleSystemParams {
        emitter: None,
        initializers: None,
        operators: Some(new_ops.clone()),
    });
    assert_eq!(sys.operators, new_ops);
}

// Phase 6A: audio binding が emit rate を加算するか
#[test]
fn audio_binding_modulates_spawn_rate() {
    let mut sys = snow_system();
    sys.audio_binding = Some(crate::audio::EmitterAudioBinding {
        band_index: 5,
        scale: 50.0,
    });
    let mut audio = crate::audio::AudioUniform::default();
    let mut bands = vec![0.0f32; 16];
    bands[5] = 1.0;
    audio.update(&bands, 0.0);
    // base spawn_rate=10 + 1.0*50 = 60/s, dt=0.1 → 6 個
    sys.simulate_cpu_with_audio(0.1, &audio);
    assert_eq!(sys.last_spawn_count, 6);
}

#[test]
fn audio_binding_none_keeps_base_rate() {
    let mut sys = snow_system();
    let audio = crate::audio::AudioUniform::default();
    // base 10/s, dt=0.1 → 1 個
    sys.simulate_cpu_with_audio(0.1, &audio);
    assert_eq!(sys.last_spawn_count, 1);
}
