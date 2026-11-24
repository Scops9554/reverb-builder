package src

import "core:os"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import vmem "core:mem/virtual"

Component_Type :: enum u8 {
    Delay,
    Delay_Bank,
    Scalar_Gain,
    Low_Pass_Bank,
    High_Pass_Bank,
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

make_components :: proc(config: Reverb_Config, list: []Config, allocator := context.allocator) -> (comps: [dynamic]^Component) {
    total_len := make([]int, config.channels, context.allocator)
    defer delete(total_len)
    for c, i in list {
        if c.type != .Delay_Bank do continue
        for length, i in c.lengths {
            total_len[i] += length
        }
    }

    comps = make([dynamic]^Component, allocator)
    for component in list {
        switch component.type {
        case .Delay_Bank:
            size := size_of(Bank(Delay_Line)) + size_of(Delay_Line) * config.channels
            bank := new(Bank(Delay_Line), allocator)
            bank.filters = make([]Delay_Line, config.channels, allocator)
            for length, i in component.lengths {
                bank.filters[i] = Delay_Line{buf = make([]f64, length, allocator)}
            }
            bank.type = .Delay_Bank
            append(&comps, bank)

        case .Delay:
            bank := new(Delay, allocator)
            bank.delay_line = Delay_Line{
                buf = make([]f64, int(config.fs * component.delay), allocator)
            }
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

        case .Low_Pass_Bank:
            bank := new(Bank(Low_Pass_Filter), allocator)
            bank.type = .Low_Pass_Bank

            damping := math.exp(-2.0 * math.PI * component.cutoff / config.fs)
            bank.filters = make([]Low_Pass_Filter, config.channels, allocator)
            slice.fill(bank.filters, Low_Pass_Filter{0, damping, 1 - damping})

            append(&comps, bank)

        case .High_Pass_Bank:
            bank := new(Bank(High_Pass_Filter), allocator)
            bank.type = .High_Pass_Bank

            bank.filters = make([]High_Pass_Filter, config.channels, allocator)
            alpha := 1 / (1 + (2 * math.PI * component.cutoff) / config.fs)
            slice.fill(bank.filters, High_Pass_Filter{alpha=alpha})

            append(&comps, bank)

        case .Biquad_Bank:
            bank := new(Bank(Biquad), allocator)
            bank.type = .Biquad_Bank

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

            bank.filters = make([]Biquad, config.channels, allocator)
            slice.fill(bank.filters, Biquad{
                a0 = b0 / a0,
                a1 = b1 / a0,
                a2 = b2 / a0,
                a3 = a1 / a0,
                a4 = a2 / a0,
            })

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

    case .Low_Pass_Bank:
        bank := cast(^Bank(Low_Pass_Filter))component
        for &filter, i in bank.filters {
            filter.store = (input[i] * filter.damp2) + (filter.store * filter.damp1)
            input[i] = filter.store
        }
    case .High_Pass_Bank:
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
    if os.args[1] == "-h" || os.args[1] == "--help" {
        fmt.eprintln("Usage: ./reverb-builder <config name> [audio file names]")
        return
    }

    config_filepath := fmt.tprintf("configs/%s.json", os.args[1])
    config, ok := load_config(config_filepath, context.temp_allocator)
    if !ok || !validate_reverb_config(config) do return

    output_directory := fmt.tprintf("output sounds/%s", os.args[1])
    if !os.is_directory(output_directory) {
        err := os.make_directory_all(output_directory)
        if err != nil {
            fmt.eprintln("Unable to create directory %s: %s", output_directory, err)
            return
        }
    }

    arena := vmem.Arena{}
    err := vmem.arena_init_growing(&arena)
    arena_allocator := vmem.arena_allocator(&arena)
    defer vmem.arena_destroy(&arena)

    pre_feedback_network := make_components(config, config.pre_feedback_network, arena_allocator)
    feedback_network := make_components(config, config.feedback_network, arena_allocator)
    post_feedback_network := make_components(config, config.post_feedback_network, arena_allocator)

    // free the files for the config since they arent needed anymore
    free_all(context.temp_allocator)

    input := make([]f64, config.channels, arena_allocator)
    feedback := make([]f64, config.channels, arena_allocator)
    scratch := make([]f64, config.channels, arena_allocator)

    assert(feedback_network[0].type == .Delay_Bank)
    main_bank := cast(^Bank(Delay_Line))feedback_network[0]

    for filename in os.args[2:] {
        relative_path := fmt.tprintf("input sounds/%s.wav", filename)
        audio := read_wav(relative_path, u32(config.fs), context.temp_allocator) or_continue
        out := make([]f32, len(audio), context.temp_allocator)
        defer free_all(context.temp_allocator)

        for sample, i in audio {
            for i in 0 ..< config.channels {
                input[i] = f64(sample)
            }

            for &component in pre_feedback_network {
                process(component, input, scratch)
            }

            for &dline, i in main_bank.filters {
                feedback[i] = read_delay_line(&dline)
            }

            for &component in feedback_network[1:] {
                process(component, feedback, scratch)
            }

            for &dline, i in main_bank.filters {
                write_delay_line(&dline, input[i] + feedback[i])
            }

            for &component in post_feedback_network {
                process(component, feedback, scratch)
            }

            sum: f32 = 0
            for s in feedback {
                sum += f32(s)
            }
            out[i] = sum / f32(config.channels)
        }

        output_filepath := fmt.tprintf("output sounds/%s/%s.wav", os.args[1], filename)
        write_wav(output_filepath, out, u32(config.fs)) or_continue
        fmt.printfln("wrote to 'output sound/%s/%s.wav'", os.args[1], filename)

        for component in feedback_network {
            switch component.type {
            case .Delay:
                delay := cast(^Delay)component
                slice.zero(delay.delay_line.buf)
            case .Delay_Bank:
                bank := cast(^Bank(Delay_Line))component
                for dline in bank.filters {
                    slice.zero(dline.buf)
                }
            case .Low_Pass_Bank:
                bank := cast(^Bank(Low_Pass_Filter))component
                for &filter in bank.filters {
                    filter.store = 0
                }
            case .High_Pass_Bank:
                bank := cast(^Bank(High_Pass_Filter))component
                for &filter in bank.filters {
                    filter.x_prev = 0
                    filter.y_prev = 0
                }
            case .Biquad_Bank:
                bank := cast(^Bank(Biquad))component
                for &b in bank.filters {
                    b.x1, b.x2, b.y1, b.y2 = 0, 0, 0, 0
                }
            case .Householder, .Scalar_Gain:
                // nothing
            }
        }
    }
}
