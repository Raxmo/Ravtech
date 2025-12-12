import core.time;
import std.math;
import std.stdio;

private immutable double PI = 3.141592653589793;

class Random
{
	// Constants for SplitMix64 PRNG (static, compile-time constants for optimization)
	static immutable long GOLDEN_RATIO = 0x9e3779b97f4a7c15;
	static immutable long MULT_A = 0xbf58476d1ce4e5b9;
	static immutable long MULT_B = 0x94d049bb133111eb;
	static immutable long DOUBLE_EXPONENT_BITS = 1023L << 52;  // [1.0, 2.0) exponent
	static immutable long MANTISSA_MASK = (1L << 52) - 1;  // 52 bits of mantissa

	private long state = 0;
	private double cachedNormal = 0;
	private bool hasCache = false;

	this()
	{
		seedFromTime();
	}

	this(long value)
	{
		seed(value);
	}

	void seed(long value) @nogc nothrow
	{
		state = value;
	}

	void seedFromTime() @nogc nothrow
	{
		state = MonoTime.currTime().ticks();
	}

	private double randDouble() @nogc nothrow pure
	{
		// Get next random long value
		long bits = next();

		// Mask lower 52 bits (highest entropy) as mantissa of double in [1.0, 2.0)
		// by bitcasting with exponent bits set to 1023
		bits = DOUBLE_EXPONENT_BITS | (bits & MANTISSA_MASK);
		double result = *(cast(double*)&bits);

		// Subtract 1.0 to get [0.0, 1.0)
		return result - 1.0;
	}

	// Function-call style RNG: rng!int(), rng!double(), rng!long(min, max), etc.
	T opCall(T)() @nogc nothrow pure
		if (is(T == double))
	{
		return randDouble();
	}

	T opCall(T)() @nogc nothrow pure
		if (is(T == long))
	{
		return next();
	}

	T opCall(T)() @nogc nothrow pure
		if (is(T == int))
	{
		return cast(int)next();
	}

	// Ranged versions
	T opCall(T)(T min, T max) @nogc nothrow pure
		if (is(T == int))
	{
		long range = max - min;
		return min + cast(T)(next() % range);
	}

	T opCall(T)(T min, T max) @nogc nothrow pure
		if (is(T == long))
	{
		long range = max - min;
		return min + cast(T)(next() % range);
	}

	// Box-Muller normal distribution with output caching
	double normal(double mean = 0.0, double stddev = 1.0) @nogc nothrow pure
	{
		if (hasCache) {
			hasCache = false;
			return mean + stddev * cachedNormal;
		}
		
		double u1 = randDouble();
		double u2 = randDouble();
		double r = sqrt(-2.0 * log(u1));
		double theta = 2.0 * PI * u2;
		
		cachedNormal = r * sin(theta);
		hasCache = true;
		
		return mean + stddev * r * cos(theta);
	}

	private long next() @nogc nothrow pure
	{
		// SplitMix64 variant for better entropy
		state += GOLDEN_RATIO;
		long x = state;
		x = (x ^ (x >> 30)) * MULT_A;
		x = x ^ (x >> 27);
		return x;
	}
}









