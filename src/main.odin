package src

import "core:os"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import vmem "core:mem/virtual"

WIDTH: f64

Component :: struct {
    type: enum u8 {
        Delay,
        Delay_Bank,
        Gain,
        Low_Pass,
        High_Pass,
        Biquad,
        Householder,
        Hadamard,
    },
    value: struct #raw_union {
        delay:      Delay_Line,
        delay_bank: []Delay_Line,
        gain:       []f64,
        high_pass:  []High_Pass,
        low_pass:   []Low_Pass,
        biquad:     []Biquad,
    }
}

Delay_Line :: struct {
    buf: []f64,
    idx: int,
}
read_delay_line :: proc(dline: ^Delay_Line) -> f64 {
    return dline.buf[dline.idx]
}
write_delay_line :: proc(dline: ^Delay_Line, input: f64) {
    dline.buf[dline.idx] = input
    dline.idx += 1
    if dline.idx == len(dline.buf) {
        dline.idx = 0
    }
}

Low_Pass :: struct{
    store: f64,
    damp1: f64,
    damp2: f64,
}

High_Pass :: struct {
    y, x, a:  f64,
}

// thanks! https://www.musicdsp.org/en/latest/Filters/64-biquad-c-code.html
Biquad :: struct {
    a0, a1, a2, a3, a4: f64,
    x1, x2, y1, y2:     f64,
}

make_components :: proc(config: Reverb_Config, list: []Config, allocator := context.allocator) -> (comps: [dynamic]Component) {
    total_len := make([]int, config.channels, context.allocator)
    defer delete(total_len)
    for comp in list {
        bank := comp.params.(Delay_Bank_Lens) or_continue
        for length, i in bank.lengths {
            total_len[i] += length
        }
    }

    comps = make([dynamic]Component, allocator)
    for component in list {
        switch component.type {
        case .Delay:
            length := int(config.fs * component.params.(Delay_Line_Len).delay)
            delay_line := Delay_Line{buf=make([]f64, length, allocator)}
            append(&comps, {.Delay, {delay=delay_line}})

        case .Delay_Bank:
            bank := make([]Delay_Line, config.channels, allocator)
            params := component.params.(Delay_Bank_Lens)
            for length, i in params.lengths {
                bank[i] = {buf = make([]f64, length, allocator)}
            }
            append(&comps, {.Delay_Bank, {delay_bank=bank}})

        case .Gain:
            gain := make([]f64, config.channels, allocator)
            for length, i in total_len {
                gain[i] = math.pow(10, (-60 * f64(length)) / (config.fs * config.rt60 * 20))
            }
            append(&comps, {.Gain, {gain=gain}})

        case .One_Pole_Filter:
            params := component.params.(One_Pole_Params)
            switch params.type {
            case .Low_Pass:
                filters := make([]Low_Pass, config.channels, allocator)
                damping := math.exp(-2 * math.PI * params.cutoff / config.fs)
                slice.fill(filters, {0, damping, 1 - damping})
                append(&comps, {.Low_Pass, {low_pass=filters}})

            case .High_Pass:
                filters := make([]High_Pass, config.channels, allocator)
                alpha := 1 / (1 + (2 * math.PI * params.cutoff) / config.fs)
                slice.fill(filters, {a=alpha})
                append(&comps, {.High_Pass, {high_pass=filters}})
            }

        case .Biquad_Filter:
            params := component.params.(Biquad_Params)
            // thanks! https://www.musicdsp.org/en/latest/Filters/64-biquad-c-code.html
            A := math.pow(10, params.peak_gain / 40)
            omega := 2 * math.PI * params.fc / config.fs
            sn := math.sin(omega)
            cs := math.cos(omega)
            alpha := sn * math.sinh(math.LN2 / 2 * params.q * omega / sn)

            b0, b1, b2: f64
            a0, a1, a2: f64

            #partial switch params.type {
            case .Low_Pass:
                b0 = (1 - cs) /2
                b1 = 1 - cs
                b2 = (1 - cs) /2
                a0 = 1 + alpha
                a1 = -2 * cs
                a2 = 1 - alpha
            case .High_Pass:
                b0 = (1 + cs) /2
                b1 = -(1 + cs)
                b2 = (1 + cs) /2
                a0 = 1 + alpha
                a1 = -2 * cs
                a2 = 1 - alpha
            case .Peaking:
                b0 = 1 + (alpha * A)
                b1 = -2 * cs
                b2 = 1 - (alpha * A)
                a0 = 1 + (alpha /A)
                a1 = -2 * cs
                a2 = 1 - (alpha /A)
            }

            filters := make([]Biquad, config.channels, allocator)
            slice.fill(filters, {
                a0 = b0 / a0,
                a1 = b1 / a0,
                a2 = b2 / a0,
                a3 = a1 / a0,
                a4 = a2 / a0,
            })

            append(&comps, {.Biquad, {biquad=filters}})

        case .Householder:
            append(&comps, {type=.Householder})

        case .Hadamard:
            append(&comps, {type=.Hadamard})
        }
    }

    return comps
}

process :: proc(comp: ^Component, input, scratch: []f64) {
    switch comp.type {
    case .Delay:
        delay := comp.value.delay
        out := read_delay_line(&delay)
        write_delay_line(&delay, math.sum(input))
        copy(input, []f64{out / WIDTH})

    case .Delay_Bank:
        bank := comp.value.delay_bank
        for &dline, i in bank {
            scratch[i] = read_delay_line(&dline)
            write_delay_line(&dline, input[i])
        }
        copy(input, scratch)

    case .Gain:
        gains := comp.value.gain
        for g, i in gains do input[i] *= g

    case .Low_Pass:
        filters := comp.value.low_pass
        for &filter, i in filters {
            filter.store = (input[i] * filter.damp2) +
                (filter.store * filter.damp1)
            input[i] = filter.store
        }

    case .High_Pass:
        filters := comp.value.high_pass
        for &f, i in filters {
            f.y = f.a * (f.y + input[i] - f.x)
            f.x = input[i]
            input[i] = f.y
        }

    // thanks! https://www.musicdsp.org/en/latest/Filters/64-biquad-c-code.html
    case .Biquad:
        filters := comp.value.biquad
        for &b, i in filters {
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
        scaled_sum := math.sum(input) * -2 / WIDTH
        for i in 0 ..< len(input) {
            input[i] += scaled_sum
        }

    case .Hadamard:
        n := len(input)
        for h := 1; h < n; h *= 2 {
            for s := 0; s < n; s += 2 * h {
                for j in s ..< s+h {
                    u := input[j]
                    v := input[j + h]
                    input[j] = u + v
                    input[j + h] = u - v
                }
            }
        }

        scale := math.sqrt_f64(1.0 / WIDTH)
        for i in 0 ..< len(input) {
            input[i] *= scale
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

    WIDTH = f64(config.channels)

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
    main_bank := feedback_network[0].value.delay_bank

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
                process(&component, input, scratch)
            }

            for &dline, i in main_bank {
                feedback[i] = read_delay_line(&dline)
            }

            for &component in feedback_network[1:] {
                process(&component, feedback, scratch)
            }

            for &dline, i in main_bank {
                write_delay_line(&dline, input[i] + feedback[i])
            }

            for &component in post_feedback_network {
                process(&component, feedback, scratch)
            }

            out[i] = f32(math.sum(feedback) / WIDTH)
        }

        output_filepath := fmt.tprintf("output sounds/%s/%s.wav", os.args[1], filename)
        write_wav(output_filepath, out, u32(config.fs)) or_continue
        fmt.printfln("wrote to 'output sound/%s/%s.wav'", os.args[1], filename)

        for comp in feedback_network {
            switch comp.type {
            case .Delay:
                slice.zero(comp.value.delay.buf)
            case .Delay_Bank:
                for dline in comp.value.delay_bank {
                    slice.zero(dline.buf)
                }
            case .Low_Pass:
                for &filter in comp.value.low_pass {
                    filter.store = 0
                }
            case .High_Pass:
                for &filter in comp.value.high_pass {
                    filter.x = 0
                    filter.y = 0
                }
            case .Biquad:
                for &b in comp.value.biquad {
                    b.x1, b.x2, b.y1, b.y2 = 0, 0, 0, 0
                }
            case .Householder,
                .Hadamard,
                .Gain:
                // nothing
            }
        }
    }
}
