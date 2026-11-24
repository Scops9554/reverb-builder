package src

import "core:os"
import "core:fmt"
import "core:encoding/json"

Config :: struct {
    type: Component_Type,

    // for delay banks
    lengths: []int,

    // for delay
    delay: f64,

    // for one-pole filters
    op_type: One_Pole_Type,
    cutoff:  f64,

    // for the biquad filters
    bq_type:   Biquad_Type,
    peak_gain: f64,
    fc:        f64,
    q:         f64,
}

Reverb_Config :: struct {
    fs:         f64,
    rt60:       f64,
    channels:   int,
    pre_feedback_network:  []Config,
    feedback_network:      []Config,
    post_feedback_network: []Config,
}

load_config :: proc(path: string, allocator := context.allocator) -> (config: Reverb_Config, ok: bool) {
    data, read_err := os.read_entire_file(path, allocator)
    if read_err != nil {
        fmt.eprintfln("Could not read config '%s': %v", path, read_err)
        return
    }

    unmarshal_err := json.unmarshal(data, &config, .JSON, allocator, {.Disallow_Unknown_Fields})
    if unmarshal_err != nil {
        fmt.eprintfln("Could not parse config '%s': %v", path, unmarshal_err)
        return
    }

    if config.channels <= 0 {
        fmt.eprintln("Config error: 'channels' must be greater than zero")
        return
    } else if config.channels & (config.channels - 1) != 0 {
        fmt.eprintln("Config error: 'channels' must be a power of 2")
        return
    }
    if config.rt60 <= 0 {
        fmt.eprintln("Config error: 'rt60' must be greater than zero")
        return
    }
    if len(config.feedback_network) == 0 {
        fmt.eprintln("Config error: 'components' must not be empty")
        return
    }
    return config, true
}

validate_reverb_config :: proc(config: Reverb_Config) -> (ok := true) {
    if config.fs <= 0 {
        fmt.eprintln("Config error: sample rate must be greater than zero")
        ok = false
    }
    if config.feedback_network[0].type != .Delay_Bank {
        fmt.eprintln("Config error: the first component of the feedback network has to be a Delay_Bank")
        ok = false
    }

    ok &= validate_component_list(config, config.pre_feedback_network)
    ok &= validate_component_list(config, config.feedback_network)
    ok &= validate_component_list(config, config.post_feedback_network)

    return ok
}

validate_component_list :: proc(config: Reverb_Config, list: []Config) -> (ok: bool) {
    for component, i in list {
        switch component.type {
        case .Delay_Bank:
            if len(component.lengths) != config.channels {
                fmt.eprintfln(
                    "Config error: components[%d] has %d delay lengths; expected %d (one per channel)",
                    i, len(component.lengths), config.channels,
                )
                return false
            }
            for length in component.lengths {
                if length <= 0 {
                    fmt.eprintfln("Config error: components[%d] has a non-positive delay length", i)
                    return false
                }
            }

        case .Delay:
            if component.delay <= 0 {
                fmt.eprintfln("Config error: components[%d] 'delay' must be greater than zero", i)
                return false
            }

        case .One_Pole_Filter:
            if component.cutoff <= 0 || component.cutoff >= config.fs * 0.5 {
                fmt.eprintfln(
                    "Config error: components[%d] cutoff must be between 0 and Nyquist (%g Hz)",
                    i, 22050,
                )
                return false
            }

        case .Biquad_Filter:
            if component.fc <= 0 || component.fc >= config.fs * 0.5 {
                fmt.eprintfln(
                    "Config error: components[%d] fc must be between 0 and Nyquist (%g Hz)",
                    i, config.fs * 0.5,
                )
                return false
            }
            if component.q <= 0 {
                fmt.eprintfln("Config error: components[%d] Q must be greater than zero", i)
                return false
            }
            if component.peak_gain == 0 {
                fmt.eprintfln("Config error: components[%d] peak_gain_rt60 must not be zero", i)
                return false
            }

        case 
            .Scalar_Gain,
            .Householder,
            .Hadamard:
            // nothing
        }
    }
    return true
}
