import core.thread;
import core.time;
import core.sync.mutex;
import core.sync.condition;
import std.variant;
import std.algorithm : filter;
import std.array : array;

struct Event
{
	Fiber fiber;
	long executeTimeNs;
	Variant payload;
	void delegate() action;
}

class EventScheduler
{
	private Event[] fibers;

	this()
	{
		// Initialize scheduler
	}

	void push(ref Event e)
	{
		// Create fiber that waits until executeTimeNs then runs action
		e.fiber = new Fiber(() {
			long targetTime = e.executeTimeNs;
			while (getCurrentTimeNs() < targetTime)
			{
				Fiber.yield();
			}
			e.action();
		});
		
		fibers ~= e;
	}

	void process(double currentTime)
	{
		// Remove finished fibers
		fibers = fibers.filter!(f => f.fiber.state != Fiber.State.TERM).array;
		
		// Resume fibers that are ready
		foreach (ref e; fibers)
		{
			if (e.fiber.state == Fiber.State.HOLD)
			{
				e.fiber.call();
			}
		}
	}

	bool hasEvents()
	{
		return fibers.length > 0;
	}

	void clear()
	{
		fibers = [];
	}

	private long getCurrentTimeNs()
	{
		return MonoTime.currTime().ticks();
	}
}

class ThreadSafeInputQueue
{
	import core.sync.mutex;

	private struct QueuedInput
	{
		void delegate() action;
		long timestamp;
	}

	private Mutex lock;
	private QueuedInput[] queue;

	this()
	{
		lock = new Mutex();
	}

	void push(void delegate() action, long timestamp)
	{
		synchronized(lock)
		{
			QueuedInput qi;
			qi.action = action;
			qi.timestamp = timestamp;
			queue ~= qi;
		}
	}

	QueuedInput[] popAll()
	{
		synchronized(lock)
		{
			auto temp = queue;
			queue = [];
			return temp;
		}
	}

	bool hasInput()
	{
		synchronized(lock)
		{
			return queue.length > 0;
		}
	}
}