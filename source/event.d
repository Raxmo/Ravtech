import core.thread;
import core.time;
import std.math;
import utils;

/**
 * ScheduledEvent - Event with Fiber and execution time (in microseconds)
 */
struct ScheduledEvent
{
	Fiber fiber;
	long executeTimeUs;  // Microseconds since epoch (from TimeUtils)
	size_t index;  // Index in the event pool, used for cancellation
}

/**
 * EventScheduler - Timeline-based event system using Fibers
 * Events are scheduled with a delay or absolute time and executed deterministically
 * when their time arrives. Single-threaded, nanosecond precision.
 */
class EventScheduler
{
	private ScheduledEvent[] events;
	
	this()
	{
		events = [];
	}
	
	/**
	 * Schedule an event to execute after a delay (microseconds)
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleEvent(long delayUs, void delegate() action)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleAtTime(executeTimeUs, action);
	}
	
	/**
	 * Schedule an event to execute at an absolute time (microseconds)
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleAtTime(long executeTimeUs, void delegate() action)
	{
		// Create fiber that runs action directly (no internal waiting)
		// Scheduler controls all timing via processEvents()
		Fiber fiber = new Fiber(() {
			action();
		});
		
		size_t idx = events.length;
		events ~= ScheduledEvent(fiber, executeTimeUs, idx);
		return events[$ - 1];
	}
	
	/**
	 * Cancel a scheduled event by reference
	 * Removes the event immediately from the pool using swap-with-last
	 * The swapped-in event's index field is updated to maintain reference validity
	 */
	void cancel(ref ScheduledEvent event)
	{
		size_t idx = event.index;
		if (idx < events.length && &events[idx] is &event)
		{
			events[idx] = events[$ - 1];
			events[idx].index = idx;  // Swapped event inherits the index
			events = events[0..$ - 1];
		}
	}
	
	/**
	 * Process all events due at current time
	 * Single pass: execute ready events and compact array in one iteration
	 */
	void processEvents()
	{
		long currentTimeUs = TimeUtils.currTimeUs();
		
		size_t writeIdx = 0;
		foreach (ref e; events)
		{
			// Skip terminated fibers entirely
			if (e.fiber.state == Fiber.State.TERM)
				continue;
			
			// Execute if ready
			if (e.executeTimeUs <= currentTimeUs)
				e.fiber.call();
			
			// Keep non-terminated fibers
			if (e.fiber.state != Fiber.State.TERM)
			{
				events[writeIdx] = e;
				events[writeIdx].index = writeIdx;
				writeIdx++;
			}
		}
		
		events = events[0..writeIdx];
	}
	
	/**
	 * Check if there are any pending non-terminated events
	 */
	bool hasEvents()
	{
		foreach (e; events)
		{
			if (e.fiber.state != Fiber.State.TERM)
				return true;
		}
		return false;
	}
	
	/**
	 * Get next event's execution time (microseconds)
	 */
	long nextEventTimeUs()
	{
		long nextTime = long.max;
		foreach (e; events)
		{
			if (e.fiber.state != Fiber.State.TERM && e.executeTimeUs < nextTime)
				nextTime = e.executeTimeUs;
		}
		return nextTime;
	}
	
	/**
	 * Clear all events
	 */
	void clear()
	{
		events = [];
	}
}

unittest
{
	import core.thread;
	import std.stdio;
	
	// Test: Basic Event Scheduling with Timing Verification (1 second)
	{
		EventScheduler scheduler = new EventScheduler();
		bool executed = false;
		long actualExecutionTimeUs;
		
		long nowUs = TimeUtils.currTimeUs();
		long scheduledTimeUs = nowUs + 1_000_000;  // 1 second in microseconds
		
		ref ScheduledEvent event = scheduler.scheduleAtTime(scheduledTimeUs, () {
			executed = true;
			actualExecutionTimeUs = TimeUtils.currTimeUs();
		});
		
		// Event should not be executed yet
		scheduler.processEvents();
		assert(!executed, "Event executed too early");
		
		// Poll processEvents until event executes
		while (!executed && TimeUtils.currTimeUs() < scheduledTimeUs + 100_000)  // 100ms timeout
		{
			scheduler.processEvents();
		}
		
		assert(executed, "Event did not execute");
		
		// Calculate timing accuracy (in microseconds)
		long errorUs = actualExecutionTimeUs - scheduledTimeUs;
		double nsPerTick = TimeUtils.getNanosecondsPerTick();
		long tps = TimeUtils.getTicksPerSecond();
		
		writeln("  Platform Resolution:");
		writeln("    ticksPerSecond: ", tps);
		writeln("    nanoseconds per tick: ", nsPerTick);
		writeln("  Scheduled: ", scheduledTimeUs, " µs");
		writeln("  Executed:  ", actualExecutionTimeUs, " µs");
		writeln("  Error:     ", errorUs, " µs (", errorUs / 1000, " ms)");
		assert(errorUs >= 0, "Event executed before scheduled time");
		assert(errorUs < 100_000, "Timing error too large (>100ms)");
	}
	
	// Test: Event Cancellation
	{
		EventScheduler scheduler = new EventScheduler();
		bool executed = false;
		
		long nowUs = TimeUtils.currTimeUs();
		long execTimeUs = nowUs + 200_000;  // 200ms in microseconds
		
		ref ScheduledEvent event = scheduler.scheduleAtTime(execTimeUs, () {
			executed = true;
		});
		
		// Cancel before execution
		scheduler.cancel(event);
		
		// Wait past execution time
		Thread.sleep(250.msecs);
		scheduler.processEvents();
		assert(!executed, "Canceled event still executed");
	}
	
	// Test: Multiple Events
	{
		EventScheduler scheduler = new EventScheduler();
		int count = 0;
		
		long nowUs = TimeUtils.currTimeUs();
		
		scheduler.scheduleAtTime(nowUs + 100_000, () { count++; });  // 100ms
		scheduler.scheduleAtTime(nowUs + 50_000, () { count++; });   // 50ms
		scheduler.scheduleAtTime(nowUs + 150_000, () { count++; });  // 150ms
		
		Thread.sleep(200.msecs);
		scheduler.processEvents();
		
		assert(count == 3, "Not all events executed");
	}
	
	// Test: hasEvents() Tracking
	{
		EventScheduler scheduler = new EventScheduler();
		assert(!scheduler.hasEvents(), "New scheduler should have no events");
		
		long nowUs = TimeUtils.currTimeUs();
		ref ScheduledEvent event = scheduler.scheduleAtTime(nowUs + 100_000, () {});
		
		assert(scheduler.hasEvents(), "Scheduler should have events after scheduling");
		
		scheduler.cancel(event);
		assert(!scheduler.hasEvents(), "Scheduler should have no events after cancellation");
	}
	
	// Test: Timing Variance with 5ms intervals (1000 events)
	{
		EventScheduler scheduler = new EventScheduler();
		long[] executionErrors;  // Timing errors in microseconds
		
		long baseTimeUs = TimeUtils.currTimeUs();
		long intervalUs = 5_000;  // 5 millisecond interval
		int eventCount = 1000;
		
		// Schedule 100 events at 50µs intervals
		for (int i = 0; i < eventCount; i++)
		{
			long scheduleTimeUs = baseTimeUs + (i * intervalUs);
			scheduler.scheduleAtTime(scheduleTimeUs, () {
				long actualTimeUs = TimeUtils.currTimeUs();
				long scheduledTimeUs = baseTimeUs + (cast(int)executionErrors.length * intervalUs);
				long errorUs = actualTimeUs - scheduledTimeUs;
				executionErrors ~= errorUs;
			});
		}
		
		// Process all events by polling
		long pollDeadlineUs = baseTimeUs + (eventCount * intervalUs) + 10_000;  // 10ms buffer
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < pollDeadlineUs)
		{
			scheduler.processEvents();
		}
		
		// Calculate statistics
		if (executionErrors.length > 0)
		{
			long minErrorUs = executionErrors[0];
			long maxErrorUs = executionErrors[0];
			long sumErrorUs = 0;
			long sumSquaredErrorUs = 0;
			
			foreach (err; executionErrors)
			{
				if (err < minErrorUs) minErrorUs = err;
				if (err > maxErrorUs) maxErrorUs = err;
				sumErrorUs += err;
				sumSquaredErrorUs += err * err;
			}
			
			long meanErrorUs = sumErrorUs / cast(long)executionErrors.length;
			long varianceUs = sumSquaredErrorUs / cast(long)executionErrors.length - (meanErrorUs * meanErrorUs);
			double stddevUs = (varianceUs >= 0) ? sqrt(cast(double)varianceUs) : 0.0;
			
			writeln("\n  Timing Variance Test (5ms intervals, ", eventCount, " events):");
			
			// Histogram of errors to show distribution
			long[] errorBuckets = [0, 0, 0, 0, 0];  // 0-50, 50-100, 100-200, 200-500, 500+
			foreach (err; executionErrors)
			{
				if (err <= 50) errorBuckets[0]++;
				else if (err <= 100) errorBuckets[1]++;
				else if (err <= 200) errorBuckets[2]++;
				else if (err <= 500) errorBuckets[3]++;
				else errorBuckets[4]++;
			}
			writeln("    Error distribution:");
			writeln("      0-50µs:   ", errorBuckets[0], " events");
			writeln("      50-100µs: ", errorBuckets[1], " events");
			writeln("      100-200µs:", errorBuckets[2], " events");
			writeln("      200-500µs:", errorBuckets[3], " events");
			writeln("      500µs+:   ", errorBuckets[4], " events");
			writeln("    Events executed: ", executionErrors.length);
			writeln("    Min error:  ", minErrorUs, " µs");
			writeln("    Max error:  ", maxErrorUs, " µs");
			writeln("    Mean error: ", meanErrorUs, " µs");
			writeln("    Stddev:     ", stddevUs, " µs");
			writeln("    Range:      ", (maxErrorUs - minErrorUs), " µs");
		}
	}
}