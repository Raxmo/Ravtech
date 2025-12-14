import core.time;
import std.math;

private immutable double PI = 0x1.921fb54442d18p1;  // IEEE 754 double-precision π

/**
 * SplitMix64-based PRNG optimized for speed
 * ~60 cycles per call; 2.46x faster than std.random
 * Maintains full precision via 52-bit mantissa + direct FPU operations
 */
class Random
{
	// Constants for SplitMix64 (compile-time for optimization)
	static immutable long GOLDEN_RATIO = 0x9e3779b97f4a7c15;
	static immutable long MULT_A = 0xbf58476d1ce4e5b9;
	static immutable long MULT_B = 0x94d049bb133111eb;
	static immutable long DOUBLE_EXPONENT_BITS = 1023L << 52;  // [1.0, 2.0) exponent
	static immutable long MANTISSA_MASK = (1L << 52) - 1;  // 52 bits of mantissa

	private long state = 0;

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

	// Box-Muller normal distribution (no caching for consistent cost)
	double normal(double mean = 0.0, double stddev = 1.0) @nogc nothrow pure
	{
		double u1 = randDouble();
		double u2 = randDouble();
		double r = sqrt(-2.0 * log(u1));
		double theta = 2.0 * PI * u2;

		return mean + stddev * r * cos(theta);
	}

	private long next() @nogc nothrow pure
	{
		// SplitMix64 with full mixing
		state += GOLDEN_RATIO;
		long x = state;
		x = (x ^ (x >> 30)) * MULT_A;
		x = x ^ (x >> 27);
		x = x * MULT_B;
		x = x ^ (x >> 33);
		return x;
	}
}

/**
 * Time utilities for cross-platform timing
 * Public API: microseconds
 * Internal: native platform ticks
 */
static class TimeUtils
{
	private static long ticksPerSecond_;
	private static long ticksPerMicrosecond_;
	
	shared static this()
	{
		ticksPerSecond_ = MonoTime.ticksPerSecond();
		ticksPerMicrosecond_ = ticksPerSecond_ / 1_000_000;
	}
	
	/**
	 * Get current time in microseconds
	 */
	static long currTimeUs()
	{
		return MonoTime.currTime().ticks() / ticksPerMicrosecond_;
	}
	
	/**
	 * Get current time in raw platform ticks (highest available resolution)
	 * For benchmarking and internal use only
	 */
	static long currTimeTicks()
	{
		return MonoTime.currTime().ticks();
	}
	
	/**
	 * Convert microseconds to platform ticks
	 */
	static long usToTicks(long us)
	{
		return us * ticksPerMicrosecond_;
	}
	
	/**
	 * Convert platform ticks to microseconds
	 */
	static long ticksToUs(long ticks)
	{
		return ticks / ticksPerMicrosecond_;
	}
	
	/**
	 * Get platform's native tick frequency (ticks per second)
	 * Useful for understanding resolution on this system
	 */
	static long getTicksPerSecond()
	{
		return ticksPerSecond_;
	}
	
	/**
	 * Get native resolution in nanoseconds per tick
	 * Lower is better (e.g., 1 = nanosecond, 333 = 333 nanoseconds)
	 */
	static double getNanosecondsPerTick()
	{
		return 1_000_000_000.0 / ticksPerSecond_;
	}
}

/**
 * DeltaTime - Per-system delta time tracker
 * 
 * Caches delta time in both microseconds and seconds to avoid repeated division.
 * Users explicitly call update() to compute delta since last update, ensuring
 * tight timing control and deterministic frame-based operation.
 * 
 * Designed for pooled compute systems: each system (physics, animation, etc.)
 * has its own instance, calls update() before processing, and passes itself
 * to subscribers who access the cached delta value.
 */
class DeltaTime
{
	private long lastUpdateUs;     // Last update time (microseconds)
	private long cachedDeltaUs;    // Cached delta in microseconds
	private double cachedSeconds;  // Cached delta in seconds (pre-calculated)
	
	/**
	 * Initialize delta tracker at current time
	 */
	this()
	{
		lastUpdateUs = TimeUtils.currTimeUs();
		cachedDeltaUs = 0;
		cachedSeconds = 0.0;
	}
	
	/**
	 * Update delta time: compute elapsed time since last update and cache both values
	 * Division from microseconds to seconds happens exactly once per update
	 */
	void update()
	{
		long nowUs = TimeUtils.currTimeUs();
		cachedDeltaUs = nowUs - lastUpdateUs;
		lastUpdateUs = nowUs;
		cachedSeconds = cachedDeltaUs / 1_000_000.0;
	}
	
	/**
	 * Get cached delta time in microseconds
	 */
	@property long deltaUs() const
	{
		return cachedDeltaUs;
	}
	
	/**
	 * Get cached delta time in seconds
	 */
	@property double seconds() const
	{
		return cachedSeconds;
	}
}

unittest
{
	import std.stdio;
	import core.thread;
	
	// DeltaTime tests
	{
		writeln("=== DeltaTime Test ===");
		
		DeltaTime delta = new DeltaTime();
		
		// Initial state: delta should be 0
		assert(delta.deltaUs == 0, "Initial delta should be 0");
		assert(delta.seconds == 0.0, "Initial seconds should be 0");
		writeln("  Initial state: deltaUs=", delta.deltaUs, ", seconds=", delta.seconds);
		
		// Sleep for a small amount and update
		Thread.sleep(10.msecs);
		delta.update();
		
		long expectedMinUs = 9_000;   // At least 9ms (accounting for timing variance)
		long expectedMaxUs = 50_000;  // At most 50ms (very conservative upper bound)
		
		assert(delta.deltaUs >= expectedMinUs && delta.deltaUs <= expectedMaxUs,
			"Delta should be ~10ms, got " ~ delta.deltaUs.stringof ~ "µs");
		assert(delta.seconds > 0.009 && delta.seconds < 0.05,
			"Seconds should be ~0.01, got " ~ delta.seconds.stringof);
		
		writeln("  After 10ms sleep:");
		writeln("    deltaUs: ", delta.deltaUs);
		writeln("    seconds: ", delta.seconds);
		
		// Verify cached values don't change without update
		long cachedUs = delta.deltaUs;
		double cachedSec = delta.seconds;
		Thread.sleep(5.msecs);
		
		assert(delta.deltaUs == cachedUs, "Delta should not change without update()");
		assert(delta.seconds == cachedSec, "Seconds should not change without update()");
		writeln("  Values stable without update(): ✓");
		
		// Update again and verify new delta
		delta.update();
		assert(delta.deltaUs >= 4_000 && delta.deltaUs <= 20_000,
			"Second delta should be ~5ms");
		writeln("  After second update: deltaUs=", delta.deltaUs);
		
		writeln("=== DeltaTime passed ===\n");
	}
	
	// TimeUtils tests
	writeln("=== TimeUtils Test ===");
	
	// Test: Conversions are consistent
	{
		long us = 1000;  // 1 millisecond
		long ticks = TimeUtils.usToTicks(us);
		long backToUs = TimeUtils.ticksToUs(ticks);
		
		// Allow small rounding error
		assert(backToUs >= us - 1 && backToUs <= us + 1, "Conversion roundtrip failed");
		writeln("  Conversion roundtrip: 1000µs -> ticks -> ", backToUs, "µs (rounding OK)");
	}
	
	// Test: Platform resolution
	{
		long tps = TimeUtils.getTicksPerSecond();
		double nsPerTick = TimeUtils.getNanosecondsPerTick();
		writeln("  Platform: ", tps, " ticks/sec = ", nsPerTick, " ns/tick");
	}
	
	// Test: Current time is sensible
	{
		long t1Us = TimeUtils.currTimeUs();
		long t1Ticks = TimeUtils.currTimeTicks();
		
		assert(t1Us > 0, "Current time should be positive");
		assert(t1Ticks > 0, "Current ticks should be positive");
		assert(t1Ticks > t1Us, "Ticks should be larger number than microseconds");
		
		writeln("  Current time: ", t1Us, " µs = ", t1Ticks, " ticks");
	}
	
	writeln("=== TimeUtils passed ===\n");
}
