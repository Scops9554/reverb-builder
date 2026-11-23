package src

import "core:strings"
import ma "vendor:miniaudio"

/*
 * documentation that I used while writing these utilities:
 *  - the official manual for the miniaudio C library:
 *    https://miniaud.io/docs/manual/index.html#DataSources
 *
 *  - the Odin programming language documentation for the bindings to the C code for miniaudio
 *    https://pkg.odin-lang.org/vendor/miniaudio/#decoder_read_pcm_frames
*/

read_wav :: proc(path: string, fs: u32, buffer_allocator := context.allocator) -> []f32 {
	cpath := strings.clone_to_cstring(path)
    defer delete(cpath)

	config := ma.decoder_config_init(ma.format.f32, 1, fs)
	decoder: ma.decoder
	init_decoder := ma.decoder_init_file(cpath, &config, &decoder)

	if init_decoder != .SUCCESS {
		panic("failed to open file")
	}

	defer ma.decoder_uninit(&decoder)

	p_length: u64
	got_amt_samples := ma.decoder_get_length_in_pcm_frames(&decoder, &p_length)

	if got_amt_samples != .SUCCESS {
		panic("could not get amount of samples")
	}

	samples := make([]f32, p_length, buffer_allocator)
	frames_read: u64

	samples_read := ma.decoder_read_pcm_frames(&decoder, &samples[0], p_length, &frames_read)

	if samples_read != .SUCCESS {
		panic("failed to read samlpes")
	}

	return samples
}

write_wav :: proc(path: string, samples: []f32, sample_rate: u32) {
	cpath := strings.clone_to_cstring(path)
    defer delete(cpath)

	config := ma.encoder_config_init(ma.encoding_format.wav, ma.format.f32, 1, sample_rate)

	encoder: ma.encoder
	file_opened := ma.encoder_init_file(cpath, &config, &encoder)

	if file_opened != .SUCCESS {
		panic("failed to open output file")
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
		panic("failed to write samples")
	}
}
