import core.time;

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

unittest
{
	import std.stdio;
	
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
