import core.thread;
import core.time;

/**
 * ScheduledEvent - Event with Fiber and execution time
 */
struct ScheduledEvent
{
	Fiber fiber;
	MonoTime executeTime;
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
	 * Schedule an event to execute after a delay
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleEvent(Duration delay, void delegate() action)
	{
		MonoTime executeTime = MonoTime.currTime() + delay;
		return scheduleAtTime(executeTime, action);
	}
	
	/**
	 * Schedule an event to execute at an absolute time
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleAtTime(MonoTime executeTime, void delegate() action)
	{
		// Create fiber that waits until executeTime, then runs action
		Fiber fiber = new Fiber(() {
			while (MonoTime.currTime() < executeTime)
			{
				Fiber.yield();
			}
			action();
		});
		
		size_t idx = events.length;
		events ~= ScheduledEvent(fiber, executeTime, idx);
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
	 */
	void processEvents()
	{
		MonoTime currentTime = MonoTime.currTime();
		
		// Remove finished fibers using swap-with-last
		size_t i = 0;
		while (i < events.length)
		{
			if (events[i].fiber.state == Fiber.State.TERM)
			{
				events[i] = events[$ - 1];
				events = events[0..$ - 1];
			}
			else
			{
				i++;
			}
		}
		
		// Resume fibers that are ready
		foreach (ref e; events)
		{
			if (e.executeTime <= currentTime && e.fiber.state != Fiber.State.TERM)
			{
				e.fiber.call();
			}
		}
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
	 * Get next event's execution time
	 */
	MonoTime nextEventTime()
	{
		MonoTime nextTime = MonoTime.max;
		foreach (e; events)
		{
			if (e.fiber.state != Fiber.State.TERM && e.executeTime < nextTime)
				nextTime = e.executeTime;
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
	
	// Test: Basic Event Scheduling with Timing Verification
	{
		EventScheduler scheduler = new EventScheduler();
		bool executed = false;
		MonoTime actualExecutionTime;
		
		MonoTime now = MonoTime.currTime();
		MonoTime scheduledTime = now + 10.msecs;
		
		ref ScheduledEvent event = scheduler.scheduleAtTime(scheduledTime, () {
			executed = true;
			actualExecutionTime = MonoTime.currTime();
		});
		
		// Event should not be executed yet
		scheduler.processEvents();
		assert(!executed, "Event executed too early");
		
		// Poll processEvents until event executes
		while (!executed && MonoTime.currTime() < scheduledTime + 100.msecs)
		{
			scheduler.processEvents();
		}
		
		assert(executed, "Event did not execute");
		
		// Calculate timing accuracy
		Duration timingError = actualExecutionTime - scheduledTime;
		long errorNs = timingError.total!"nsecs";
		writeln("  Scheduled: ", scheduledTime);
		writeln("  Executed:  ", actualExecutionTime);
		writeln("  Error:     ", errorNs, " ns");
		assert(timingError >= Duration.zero, "Event executed before scheduled time");
		assert(timingError < 1.msecs, "Timing error too large");
	}
	
	// Test: Event Cancellation
	{
		EventScheduler scheduler = new EventScheduler();
		bool executed = false;
		
		MonoTime now = MonoTime.currTime();
		MonoTime execTime = now + 200.msecs;
		
		ref ScheduledEvent event = scheduler.scheduleAtTime(execTime, () {
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
		
		MonoTime now = MonoTime.currTime();
		
		scheduler.scheduleAtTime(now + 100.msecs, () { count++; });
		scheduler.scheduleAtTime(now + 50.msecs, () { count++; });
		scheduler.scheduleAtTime(now + 150.msecs, () { count++; });
		
		Thread.sleep(200.msecs);
		scheduler.processEvents();
		
		assert(count == 3, "Not all events executed");
	}
	
	// Test: hasEvents() Tracking
	{
		EventScheduler scheduler = new EventScheduler();
		assert(!scheduler.hasEvents(), "New scheduler should have no events");
		
		MonoTime now = MonoTime.currTime();
		ref ScheduledEvent event = scheduler.scheduleAtTime(now + 100.msecs, () {});
		
		assert(scheduler.hasEvents(), "Scheduler should have events after scheduling");
		
		scheduler.cancel(event);
		assert(!scheduler.hasEvents(), "Scheduler should have no events after cancellation");
	}
}