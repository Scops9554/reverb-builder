A program that you can use to build feedback delay network reverberators.

Its components are a delay (line), a bank of parallel delay lines, Householder and Hadamard matrices, one-pole filters (high and low pass) and biquad filters (high pass, low pass, peaking EQ). This means it's simple but still flexible enough to do a fair bit with.

#### Requirements:
All you need to run this is the Odin compiler, available at https://github.com/odin-lang/Odin.

#### CAUTION:
If you use a biquad filter to boost certain frequencies, and they are not compensated down to unity gain or less by other components in the configuration, the system will very quickly build up energy and you will blow your ears out. You have been warned.

(Tip: you can generate an impulse response and view it in Room EQ Wizard to check if their is anything funny with your config)
