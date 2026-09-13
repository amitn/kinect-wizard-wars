using System;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.Kinect;

namespace KinectBridge
{
    /// <summary>
    /// Reads body frames from the Kinect v2 and streams every tracked skeleton as one
    /// JSON datagram per frame (~30 Hz). The Godot game listens on the other end.
    ///
    /// Packet shape:
    /// {
    ///   "t": 123456.7,                      // sensor relative time in ms
    ///   "bodies": [
    ///     {
    ///       "id": "72057594037927938",      // Kinect tracking id, stable while tracked
    ///       "hands": {"l": "open", "r": "closed"},
    ///       "joints": {"Head": [x, y, z, state], ...}   // camera space meters, state 0/1/2
    ///     }
    ///   ]
    /// }
    /// </summary>
    internal static class Program
    {
        private static int Main(string[] args)
        {
            string host = args.Length > 0 ? args[0] : "127.0.0.1";
            int port = args.Length > 1 ? int.Parse(args[1], CultureInfo.InvariantCulture) : 7777;

            KinectSensor sensor = KinectSensor.GetDefault();
            if (sensor == null)
            {
                Console.Error.WriteLine("No Kinect sensor found. Is the Kinect SDK 2.0 installed and the sensor on USB 3.0?");
                return 1;
            }

            var udp = new UdpClient();
            var endpoint = new IPEndPoint(IPAddress.Parse(host), port);
            var json = new StringBuilder(16 * 1024);
            Body[] bodies = null;
            long frames = 0;

            BodyFrameReader reader = sensor.BodyFrameSource.OpenReader();
            reader.FrameArrived += (sender, e) =>
            {
                using (BodyFrame frame = e.FrameReference.AcquireFrame())
                {
                    if (frame == null) return;
                    if (bodies == null) bodies = new Body[frame.BodyCount];
                    frame.GetAndRefreshBodyData(bodies);

                    int tracked = WriteFrame(json, frame.RelativeTime.TotalMilliseconds, bodies);
                    byte[] payload = Encoding.UTF8.GetBytes(json.ToString());
                    try { udp.Send(payload, payload.Length, endpoint); }
                    catch (SocketException ex) { Console.Error.WriteLine("send failed: " + ex.Message); }

                    frames++;
                    if (frames % 30 == 0)
                        Console.Write("\rframes {0}   tracked bodies {1}   ", frames, tracked);
                }
            };

            sensor.Open();
            Console.WriteLine("Kinect bridge streaming to {0}:{1}. Press Enter to stop.", host, port);
            Console.ReadLine();

            reader.Dispose();
            sensor.Close();
            udp.Close();
            return 0;
        }

        private static int WriteFrame(StringBuilder sb, double timeMs, Body[] bodies)
        {
            var inv = CultureInfo.InvariantCulture;
            int tracked = 0;
            sb.Clear();
            sb.Append("{\"t\":").Append(timeMs.ToString("F1", inv)).Append(",\"bodies\":[");
            foreach (Body body in bodies)
            {
                if (body == null || !body.IsTracked) continue;
                if (tracked > 0) sb.Append(',');
                tracked++;

                sb.Append("{\"id\":\"").Append(body.TrackingId.ToString(inv)).Append("\",");
                sb.Append("\"hands\":{\"l\":\"").Append(HandName(body.HandLeftState))
                  .Append("\",\"r\":\"").Append(HandName(body.HandRightState)).Append("\"},");
                sb.Append("\"joints\":{");
                bool first = true;
                foreach (var kv in body.Joints)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    Joint j = kv.Value;
                    sb.Append('"').Append(kv.Key.ToString()).Append("\":[")
                      .Append(j.Position.X.ToString("F3", inv)).Append(',')
                      .Append(j.Position.Y.ToString("F3", inv)).Append(',')
                      .Append(j.Position.Z.ToString("F3", inv)).Append(',')
                      .Append((int)j.TrackingState).Append(']');
                }
                sb.Append("}}");
            }
            sb.Append("]}");
            return tracked;
        }

        private static string HandName(HandState state)
        {
            switch (state)
            {
                case HandState.Open: return "open";
                case HandState.Closed: return "closed";
                case HandState.Lasso: return "lasso";
                case HandState.NotTracked: return "not_tracked";
                default: return "unknown";
            }
        }
    }
}
