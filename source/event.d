import core.thread;
import core.time;
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
}