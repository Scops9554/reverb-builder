package src

import "core:os"
import "core:fmt"
import "core:encoding/json"

Config :: struct {
    type:  enum u8 {
        Delay,
        Delay_Bank,
        Gain,
        One_Pole_Filter,
        Biquad_Filter,
        Householder,
        Hadamard,
    },
    params: union {
        Delay_Line_Len,
        Delay_Bank_Lens,
        One_Pole_Params,
        Biquad_Params,
    }
}

Delay_Line_Len :: struct {
    delay: f64,
}

Delay_Bank_Lens :: struct {
    lengths: []int,
}

One_Pole_Params :: struct {
    type:   enum u8 {
        Low_Pass,
        High_Pass,
    },
    cutoff: f64,
}

Biquad_Params :: struct {
    type: enum u32 {
        Low_Pass,
        High_Pass,
        Peaking,
    },
    peak_gain: f64,
    fc: f64,
    q:  f64,
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

validate_reverb_config :: proc(config: Reverb_Config) -> (ok: bool) {
    n_errs := 0
    if config.fs <= 0 {
        fmt.eprintln("Config error: sample rate must be greater than zero")
        n_errs += 1
    }
    if config.feedback_network[0].type != .Delay_Bank {
        fmt.eprintln("Config error: the first component of the feedback network has to be a Delay_Bank")
        n_errs += 1
    }

    n_errs += validate_component_list(config, config.pre_feedback_network)
    n_errs += validate_component_list(config, config.feedback_network)
    n_errs += validate_component_list(config, config.post_feedback_network)

    return n_errs == 0
}

config_type_error :: proc(name: string, i: int) {
    fmt.eprintfln("Invalid parameters for component [%d], type %s.", i+1, name)
}

validate_component_list :: proc(config: Reverb_Config, list: []Config) -> (n_errs: int) {
    comps: for comp, i in list {
        switch comp.type {
        case .Delay:
            param, ok := comp.params.(Delay_Line_Len)
            if !ok {
                n_errs += 1
                config_type_error("Delay", i)
                continue comps
            }
            if param.delay <= 0 {
                fmt.eprintfln("Config error: component [%d] 'delay' must be greater than zero", i+1)
                n_errs += 1
            }

        case .Delay_Bank:
            params, ok := comp.params.(Delay_Bank_Lens)
            if !ok {
                n_errs += 1
                config_type_error("Delay", i)
                continue comps
            }
            if len(params.lengths) != config.channels {
                fmt.eprintfln(
                    "Config error: component [%d] has %d delay params; expected %d (one per channel)",
                    i+1, len(params.lengths), config.channels,
                )
                n_errs += 1
            }
            for length in params.lengths {
                if length <= 0 {
                    fmt.eprintfln("Config error: component [%d] has a non-positive delay length", i+1)
                    n_errs += 1
                }
            }

        case .One_Pole_Filter:
            params, ok := comp.params.(One_Pole_Params)
            if !ok {
                n_errs += 1
                config_type_error("Delay", i)
                continue comps
            }
            if params.cutoff <= 0 || params.cutoff >= config.fs * 0.5 {
                fmt.eprintfln(
                    "Config error: component [%d] cutoff must be between 0 and Nyquist (%g Hz)",
                    i+1, 22050,
                )
                n_errs += 1
            }

        case .Biquad_Filter:
            params, ok := comp.params.(Biquad_Params)
            if !ok {
                n_errs += 1
                config_type_error("Delay", i)
                continue comps
            }
            if params.fc <= 0 || params.fc >= config.fs * 0.5 {
                fmt.eprintfln(
                    "Config error: paramss[%d] fc must be between 0 and Nyquist (%g Hz)",
                    i+1, config.fs * 0.5,
                )
                n_errs += 1
            }
            if params.q <= 0 {
                fmt.eprintfln("Config error: component [%d] Q must be greater than zero", i+1)
                n_errs += 1
            }
            if params.peak_gain == 0 {
                fmt.eprintfln("Config error: component [%d] peak_gain_rt60 must not be zero", i+1)
                n_errs += 1
            }

        case .Gain,
            .Householder,
            .Hadamard:
            if comp.params != nil {
                fmt.eprintfln("Config error: component [%d] did not expect any parameters", i+1)
            }
            // nothing
        }
    }
    return n_errs
}
