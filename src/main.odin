package src

import "core:os"
import "core:fmt"
import "core:time"
import "core:math"
import "core:mem"
import vmem "core:mem/virtual"

Component_Type :: enum {
    Delay,
    Delay_Bank,
    Scalar_Gain,
    Low_Pass_Filter_Bank,
    High_Pass_Filter_Bank,
    Biquad_Bank,
    Householder,
}

Component :: struct {
    type: Component_Type,
}

Bank :: struct($T: typeid) {
    using header: Component,
    filters:     []T,
}

Delay_Line :: struct {
    buf: []f64,
    ptr: int,
}
read_delay_line :: proc(dline: ^Delay_Line) -> f64 {
    return dline.buf[dline.ptr]
}
write_delay_line :: proc(dline: ^Delay_Line, input: f64) {
    dline.buf[dline.ptr] = input
    dline.ptr += 1
    if dline.ptr == len(dline.buf) {
        dline.ptr = 0
    }
}

Delay :: struct {
    using header: Component,
    delay_line:   Delay_Line,
}

Low_Pass_Filter :: struct{
    store, damp1, damp2: f64,
}

High_Pass_Filter :: struct {
    y_prev: f64,
    x_prev: f64,
    alpha:  f64,
}

Biquad :: struct {
    a0, a1, a2, a3, a4: f64,
    x1, x2, y1, y2:     f64,
}

Householder :: struct {
    using header: Component,
    scale:        f64,
}

make_components :: proc(config: Reverb_Config, allocator := context.allocator) -> (comps: [dynamic]^Component) {
    total_len := make([]int, config.channels, context.allocator)
    defer delete(total_len)
    for c, i in config.components {
        if c.type != .Delay_Bank do continue
        for len, i in c.lengths {
            total_len[i] += len
        }
    }

    fmt.println(total_len)

    comps = make([dynamic]^Component, allocator)
    for component in config.components {
        switch component.type {
        case .Delay_Bank:
            bank := new(Bank(Delay_Line), allocator)
            bank.filters = make([]Delay_Line, config.channels, allocator)
            for length, i in component.lengths {
                bank.filters[i] = Delay_Line{buf = make([]f64, length, allocator)}
            }
            bank.type = .Delay_Bank
            append(&comps, bank)

        case .Delay:
            bank := new(Delay, allocator)
            assert(len(component.lengths) == 1)
            bank.delay_line = Delay_Line{buf = make([]f64, component.delay, allocator)}

            bank.type = .Delay
            append(&comps, bank)

        case .Scalar_Gain:
            scalar_gain := new(Bank(f64), allocator)
            scalar_gain.filters = make([]f64, config.channels, allocator)

            for length, i in total_len {
                scalar_gain.filters[i] =
                    math.pow(10, (-60 * f64(length)) / (config.fs * config.rt60 * 20))
            }

            scalar_gain.type = .Scalar_Gain
            append(&comps, scalar_gain)

        case .Low_Pass_Filter_Bank:
            bank := new(Bank(Low_Pass_Filter), allocator)
            bank.filters = make([]Low_Pass_Filter, config.channels, allocator)

            for length, i in total_len {
                damping := math.exp(-2.0 * math.PI * component.cutoff / config.fs)
                bank.filters[i] = Low_Pass_Filter{0, damping, 1 - damping}
            }

            bank.type = .Low_Pass_Filter_Bank
            append(&comps, bank)

        case .High_Pass_Filter_Bank:
            bank := new(Bank(High_Pass_Filter), allocator)
            bank.filters = make([]High_Pass_Filter, config.channels, allocator)

            for length, i in total_len {
                alpha := 1 / (1 + (2 * math.PI * component.cutoff) / config.fs)
                bank.filters[i] = High_Pass_Filter{alpha=alpha}
            }

            bank.type = .High_Pass_Filter_Bank
            append(&comps, bank)

        case .Biquad_Bank:
            bank := new(Bank(Biquad), allocator)
            bank.filters = make([]Biquad, config.channels, allocator)

            for length, i in total_len {
                A := math.pow(10, component.peak_gain / 40)
                omega := 2.0 * math.PI * component.fc / config.fs
                sn := math.sin(omega)
                cs := math.cos(omega)
                alpha := sn * math.sinh(math.LN2 / 2 * component.Q * omega / sn)

                b0 := 1.0 + (alpha * A)
                b1 := -2.0 * cs
                b2 := 1.0 - (alpha * A)

                a0 := 1.0 + (alpha / A)
                a1 := -2.0 * cs
                a2 := 1.0 - (alpha / A)

                bank.filters[i] = {
                    a0 = b0 / a0,
                    a1 = b1 / a0,
                    a2 = b2 / a0,
                    a3 = a1 / a0,
                    a4 = a2 / a0,
                }
            }

            bank.type = .Biquad_Bank
            append(&comps, bank)

        case .Householder:
            householder := new(Householder, allocator)
            householder.scale = -2 / f64(config.channels)
            householder.type = .Householder
            append(&comps, householder)
        }
    }

    return comps
}

process :: proc(component: ^Component, input, scratch: []f64) {
    switch component.type {
    case .Delay:
        bank := cast(^Delay)component
        temp := read_delay_line(&bank.delay_line)
        sum: f64
        for chan in input do sum += chan
        write_delay_line(&bank.delay_line, sum)
        copy(input, []f64{temp / f64(len(input))})

    case .Delay_Bank:
        bank := cast(^Bank(Delay_Line))component
        for &dline, i in bank.filters {
            scratch[i] = read_delay_line(&dline)
            write_delay_line(&dline, input[i])
        }
        copy(input, scratch)

    case .Scalar_Gain:
        bank := cast(^Bank(f64))component
        gains := cast(^Bank(f64))component
        for g, i in gains.filters do input[i] *= g

    case .Low_Pass_Filter_Bank:
        bank := cast(^Bank(Low_Pass_Filter))component
        for &filter, i in bank.filters {
            filter.store = (input[i] * filter.damp2) + (filter.store * filter.damp1)
            input[i] = filter.store
        }
    case .High_Pass_Filter_Bank:
        bank := cast(^Bank(High_Pass_Filter))component
        for &filter, i in bank.filters {
            filter.y_prev = filter.alpha * (filter.y_prev + input[i] - filter.x_prev)
            filter.x_prev = input[i]
            input[i] = filter.y_prev
        }
    case .Biquad_Bank:
        bank := cast(^Bank(Biquad))component
        for &b, i in bank.filters {
            result :=
                b.a0 * input[i] +
                b.a1 * b.x1 +
                b.a2 * b.x2 -
                b.a3 * b.y1 -
                b.a4 * b.y2

            b.x2 = b.x1
            b.x1 = input[i]

            b.y2 = b.y1
            b.y1 = result

            input[i] = result
        }
    case .Householder:
        matr := cast(^Householder)component
        sum: f64 = 0
        for i in 0 ..< len(input) {
            sum += input[i]
        }
        sum *= f64(matr.scale)
        for i in 0 ..< len(input) {
            input[i] += sum
        }
    }
}

main :: proc() {
    defer free_all(context.temp_allocator)
    config, ok := load_config("config.json", context.temp_allocator)
    if ok := validate_reverb_config(config); !ok do return

    arena := vmem.Arena{}
    err := vmem.arena_init_growing(&arena)
    arena_allocator := vmem.arena_allocator(&arena)
    defer vmem.arena_destroy(&arena)

    fmt.println(config)
    components := make_components(config, arena_allocator)
    index := config.primary_delay_bank_index

    // free the files for the config since they arent needed anymore
    free_all(context.temp_allocator)

    audio := read_wav(fmt.tprintf("input sounds/%s.wav", os.args[1]), u32(config.fs), arena_allocator)

    out := make([]f32, len(audio), arena_allocator)
    input := make([]f64, config.channels, arena_allocator)
    feedback := make([]f64, config.channels, arena_allocator)
    scratch := make([]f64, config.channels, arena_allocator)

    now := time.now()

    core := cast(^Bank(Delay_Line))components[index]
    for sample, i in audio {
        for i in 0 ..< config.channels {
            input[i] = f64(sample)
        }

        for &component in components[:index] {
            process(component, input, scratch)
        }

        for &dline, i in core.filters {
            feedback[i] = read_delay_line(&dline)
        }

        for &component in components[index+1:] {
            process(component, feedback, scratch)
        }

        for &dline, i in core.filters {
            write_delay_line(&dline, input[i] + feedback[i])
        }

        sum: f32 = 0
        for s in feedback {
            sum += f32(s)
        }
        out[i] = sum / f32(config.channels)
    }

    total_time := time.duration_seconds(time.since(now))
    fmt.printfln(
        "The reverb took %f seconds to process, which is %f times faster than real time.",
        total_time,
         f64(len(audio) / int(config.fs)) / total_time
    )

    write_wav(fmt.tprintf("output sounds/%s.wav", os.args[1]), out, u32(config.fs))
}

// please work
