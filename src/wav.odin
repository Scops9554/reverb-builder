package src

import "core:fmt"
import "core:strings"
import ma "vendor:miniaudio"

@(require_results)
read_wav :: proc(path: string, fs: u32, buffer_allocator := context.allocator) -> (audio: []f32, ok: bool) {
	cpath := strings.clone_to_cstring(path)
    defer delete(cpath)

	config := ma.decoder_config_init(ma.format.f32, 1, fs)
	decoder: ma.decoder
	init_decoder := ma.decoder_init_file(cpath, &config, &decoder)

	if init_decoder != .SUCCESS {
		fmt.eprintln("Error openning input file '%s'", path)
        return nil, false
	}

	defer ma.decoder_uninit(&decoder)

	p_length: u64
	got_amt_samples := ma.decoder_get_length_in_pcm_frames(&decoder, &p_length)

	if got_amt_samples != .SUCCESS {
		fmt.eprintln("Error reading from input file '%s'", path)
        return nil, false
	}

	audio = make([]f32, p_length, buffer_allocator)
	frames_read: u64

	samples_read := ma.decoder_read_pcm_frames(&decoder, &audio[0], p_length, &frames_read)

	if samples_read != .SUCCESS {
		fmt.eprintln("Failed to read from input file '%s'", path)
        return nil, false
	}

	return audio, true
}

@(require_results)
write_wav :: proc(path: string, samples: []f32, sample_rate: u32) -> (ok: bool) {
	cpath := strings.clone_to_cstring(path)
    defer delete(cpath)

	config := ma.encoder_config_init(ma.encoding_format.wav, ma.format.f32, 1, sample_rate)

	encoder: ma.encoder
	file_opened := ma.encoder_init_file(cpath, &config, &encoder)

	if file_opened != .SUCCESS {
		fmt.eprintln("failed to open output file '%s'", path)
        return false
	}

	defer ma.encoder_uninit(&encoder)

	frames_written: u64

	data_writen := ma.encoder_write_pcm_frames(
		&encoder,
		&samples[0],
		u64(len(samples)),
		&frames_written,
	)

	if data_writen != .SUCCESS {
		fmt.eprintln("failed to write to output file '%s'", path)
        return false
	}

    return true
}
