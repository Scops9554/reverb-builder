package src

import "core:os"
import "core:fmt"
import "core:encoding/json"

Config :: struct {
    type: Component_Type,

    // for delay banks
    lengths: []int,

    // for delay
    delay: int,

    // for low and high pass filters
    cutoff: f64,

    // for the biquad filters
    peak_gain:   f64,
    fc: f64,
    Q:  f64,
}

Config_JSON :: struct {
    is_primary_delay_bank: bool,
    type:      string,
    lengths:   []int,
    delay:     int,
    cutoff:    f64,
    peak_gain: f64,
    fc:        f64,
    q:         f64,
}

Reverb_Config_JSON :: struct {
    fs:          f64,
    rt60:        f64,
    channels:    int,
    components:  []Config_JSON,
}

Reverb_Config :: struct {
    fs:         f64,
    rt60:       f64,
    channels:   int,
    components: []Config,
    primary_delay_bank_index: int,
}

config_type_from_string :: proc(name: string) -> (kind: Component_Type, ok: bool) {
    switch name {
    case "Delay":
        return .Delay, true
    case "Delay_Bank":
        return .Delay_Bank, true
    case "Scalar_Gain":
        return .Scalar_Gain, true
    case "Low_Pass_Filter_Bank":
        return .Low_Pass_Filter_Bank, true
    case "High_Pass_Filter_Bank":
        return .High_Pass_Filter_Bank, true
    case "Biquad_Bank":
        return .Biquad_Bank, true
    case "Householder":
        return .Householder, true
    }

    return .Delay, false
}

load_config :: proc(path: string, allocator := context.allocator) -> (config: Reverb_Config, ok: bool) {
    data, read_err := os.read_entire_file(path, allocator)
    if read_err != nil {
        fmt.eprintfln("Could not read config '%s': %v", path, read_err)
        return
    }

    raw: Reverb_Config_JSON
    unmarshal_err := json.unmarshal(data, &raw, .JSON, allocator, {.Disallow_Unknown_Fields})

    if unmarshal_err != nil {
        fmt.eprintfln("Could not parse config '%s': %v", path, unmarshal_err)
        return
    }

    if raw.channels <= 0 {
        fmt.eprintln("Config error: 'channels' must be greater than zero")
        return
    } else if raw.channels & (raw.channels - 1) != 0 {
        fmt.eprintln("Config error: 'channels' must be a power of 2")
        return
    }
    if raw.rt60 <= 0 {
        fmt.eprintln("Config error: 'rt60' must be greater than zero")
        return
    }
    if len(raw.components) == 0 {
        fmt.eprintln("Config error: 'components' must not be empty")
        return
    }

    config.fs = raw.fs
    config.rt60 = raw.rt60
    config.channels = raw.channels
    config.components = make([]Config, len(raw.components), allocator)
    config.primary_delay_bank_index = -1

    for source, i in raw.components {
        kind, type_ok := config_type_from_string(source.type)
        if !type_ok {
            fmt.eprintfln("Config error: components[%d] has unknown type '%s'", i, source.type)
            return
        }

        if source.is_primary_delay_bank {
            if config.primary_delay_bank_index != -1 {
                fmt.eprintfln(
                    "Config error: components [%d] and [%d] set as primary delay bank '%s'",
                    config.primary_delay_bank_index, i
                )
                return
            }
            config.primary_delay_bank_index = i
        }

        config.components[i] = Config{
            type      = kind,
            lengths   = source.lengths,
            delay     = source.delay,
            cutoff    = source.cutoff,
            peak_gain = source.peak_gain,
            fc        = source.fc,
            Q         = source.q,
        }
    }

    if config.primary_delay_bank_index == -1 {
        fmt.eprintln("Config error: no primary delay bank is set by the config")
        return
    }

    return config, true
}

validate_reverb_config :: proc(config: Reverb_Config) -> bool {
    if config.fs <= 0 {
        fmt.eprintln("Config error: sample rate must be greater than zero")
        return false
    }

    has_feedback_delay_bank := false

    for component, i in config.components {
        switch component.type {
        case .Delay_Bank:
            has_feedback_delay_bank = true

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

        case .Low_Pass_Filter_Bank, .High_Pass_Filter_Bank:
            if component.cutoff <= 0 || component.cutoff >= config.fs * 0.5 {
                fmt.eprintfln(
                    "Config error: components[%d] cutoff must be between 0 and Nyquist (%g Hz)",
                    i, config.fs * 0.5,
                )
                return false
            }

        case .Biquad_Bank:
            if component.fc <= 0 || component.fc >= config.fs * 0.5 {
                fmt.eprintfln(
                    "Config error: components[%d] fc must be between 0 and Nyquist (%g Hz)",
                    i, config.fs * 0.5,
                )
                return false
            }
            if component.Q <= 0 {
                fmt.eprintfln("Config error: components[%d] Q must be greater than zero", i)
                return false
            }
            if component.peak_gain == 0 {
                fmt.eprintfln("Config error: components[%d] peak_gain_rt60 must not be zero", i)
                return false
            }

        case .Scalar_Gain, .Householder:
            // nothing
        }
    }

    if !has_feedback_delay_bank {
        fmt.eprintln("Config error: at least one Delay_Bank is required for the feedback loop")
        return false
    }

    return true
}
