A program that you can use to build feedback delay network reverberators.

Its components are a delay (line), a bank of parallel delay lines, Householder and Hadamard matrices, one-pole filters (high and low pass) and biquad filters (high pass, low pass, peaking EQ). This means that it is simple but still flexible to do a lot with.

### CAUTION:
If you use a biquad filter to boost certain frequencies, and they are not compensated down to unity or less by other components in the configuration, the system will very quickly build up energy and you will blow your ears out. You have been warned.
