module WebSocket
  class Driver

    class Hybi < Driver
      root = File.expand_path('../hybi', __FILE__)

      autoload :Frame,        root + '/frame'
      autoload :Message,      root + '/message'
      autoload :StreamReader, root + '/stream_reader'

      def self.generate_accept(key)
        Base64.encode64(Digest::SHA1.digest(key + GUID)).strip
      end

      GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

      BYTE       = 0b11111111
      FIN = MASK = 0b10000000
      RSV1       = 0b01000000
      RSV2       = 0b00100000
      RSV3       = 0b00010000
      OPCODE     = 0b00001111
      LENGTH     = 0b01111111

      OPCODES = {
        :continuation => 0,
        :text         => 1,
        :binary       => 2,
        :close        => 8,
        :ping         => 9,
        :pong         => 10
      }

      OPCODE_CODES    = OPCODES.values
      MESSAGE_OPCODES = OPCODES.values_at(:continuation, :text, :binary)
      OPENING_OPCODES = OPCODES.values_at(:text, :binary)

      ERRORS = {
        :normal_closure       => 1000,
        :going_away           => 1001,
        :protocol_error       => 1002,
        :unacceptable         => 1003,
        :encoding_error       => 1007,
        :policy_violation     => 1008,
        :too_large            => 1009,
        :extension_error      => 1010,
        :unexpected_condition => 1011
      }

      ERROR_CODES        = ERRORS.values
      MIN_RESERVED_ERROR = 3000
      MAX_RESERVED_ERROR = 4999

      def initialize(socket, options = {})
        super

        @extensions      = ::WebSocket::Extensions.new
        @reader          = StreamReader.new
        @stage           = 0
        @masking         = options[:masking]
        @protocols       = options[:protocols] || []
        @protocols       = @protocols.strip.split(/ *, */) if String === @protocols
        @require_masking = options[:require_masking]
        @ping_callbacks  = {}

        return unless @socket.respond_to?(:env)

        sec_key = @socket.env['HTTP_SEC_WEBSOCKET_KEY']
        protos  = @socket.env['HTTP_SEC_WEBSOCKET_PROTOCOL']

        @headers['Upgrade'] = 'websocket'
        @headers['Connection'] = 'Upgrade'
        @headers['Sec-WebSocket-Accept'] = Hybi.generate_accept(sec_key)

        if protos = @socket.env['HTTP_SEC_WEBSOCKET_PROTOCOL']
          protos = protos.split(/ *, */) if String === protos
          @protocol = protos.find { |p| @protocols.include?(p) }
          @headers['Sec-WebSocket-Protocol'] = @protocol if @protocol
        end
      end

      def version
        "hybi-#{@socket.env['HTTP_SEC_WEBSOCKET_VERSION']}"
      end

      def add_extension(extension)
        @extensions.add(extension)
        true
      end

      def parse(data)
        data = data.bytes.to_a if data.respond_to?(:bytes)
        @reader.put(data)
        buffer = true
        while buffer
          case @stage
            when 0 then
              buffer = @reader.read(1)
              parse_opcode(buffer[0]) if buffer

            when 1 then
              buffer = @reader.read(1)
              parse_length(buffer[0]) if buffer

            when 2 then
              buffer = @reader.read(@frame.length_bytes)
              parse_extended_length(buffer) if buffer

            when 3 then
              buffer = @reader.read(4)
              if buffer
                @frame.masking_key = buffer
                @stage = 4
              end

            when 4 then
              buffer = @reader.read(@frame.length)
              if buffer
                emit_frame(buffer)
                @stage = 0
              end

            else
              buffer = nil
          end
        end
      end

      def text(message)
        frame(message, :text)
      end

      def binary(message)
        frame(message, :binary)
      end

      def ping(message = '', &callback)
        @ping_callbacks[message] = callback if callback
        frame(message, :ping)
      end

      def close(reason = nil, code = nil)
        reason ||= ''
        code   ||= ERRORS[:normal_closure]

        if @ready_state <= 0
          @ready_state = 3
          emit(:close, CloseEvent.new(code, reason))
          true
        elsif @ready_state == 1
          frame(reason, :close, code)
          @ready_state = 2
          true
        else
          false
        end
      end

      def frame(data, type = nil, code = nil)
        return queue([data, type, code]) if @ready_state <= 0
        return false unless @ready_state == 1

        data = data.to_s unless Array === data
        data = Driver.encode(data, :utf8) if String === data

        frame   = Frame.new
        is_text = (String === data)

        frame.final  = true
        frame.rsv1   = frame.rsv2 = frame.rsv3 = false
        frame.opcode = OPCODES[type || (is_text ? :text : :binary)]
        frame.masked = !!@masking

        frame.masking_key = SecureRandom.random_bytes(4).bytes.to_a if frame.masked

        payload = data.respond_to?(:bytes) ? data.bytes.to_a : data
        if code
          payload = [(code >> 8) & BYTE, code & BYTE] + payload
        end
        frame.length  = payload.size
        frame.payload = payload

        send_frame(frame, true)
        true
      end

    private

      def send_frame(frame, run_extensions = false)
        if run_extensions and MESSAGE_OPCODES.include?(frame.opcode)
          message = Message.new
          message << frame

          @extensions.process_outgoing_message(message).frames.each do |frame|
            send_frame(frame)
          end
          return
        end

        length = frame.length
        header = (length <= 125) ? 2 : (length <= 65535 ? 4 : 10)
        offset = header + (frame.masked ? 4 : 0)
        masked = frame.masked ? MASK : 0

        buffer = [FIN | frame.opcode]

        if length <= 125
          buffer[1] = masked | length
        elsif length <= 65535
          buffer[1] = masked | 126
          buffer[2] = (length >> 8) & BYTE
          buffer[3] = length & BYTE
        else
          buffer[1] = masked | 127
          buffer[2] = (length >> 56) & BYTE
          buffer[3] = (length >> 48) & BYTE
          buffer[4] = (length >> 40) & BYTE
          buffer[5] = (length >> 32) & BYTE
          buffer[6] = (length >> 24) & BYTE
          buffer[7] = (length >> 16) & BYTE
          buffer[8] = (length >> 8)  & BYTE
          buffer[9] = length & BYTE
        end

        if frame.masked
          buffer.concat(frame.masking_key)
          buffer.concat(Mask.mask(frame.payload, frame.masking_key))
        else
          buffer.concat(frame.payload)
        end

        @socket.write(Driver.encode(buffer, :binary))

      rescue ::WebSocket::Extensions::ExtensionError => e
        fail(:extension_error, e.message)
      end

      def handshake_response
        extensions = @extensions.generate_response(@socket.env['HTTP_SEC_WEBSOCKET_EXTENSIONS'])
        @headers['Sec-WebSocket-Extensions'] = extensions if extensions

        start   = 'HTTP/1.1 101 Switching Protocols'
        headers = [start, @headers.to_s, '']
        headers.join("\r\n")
      end

      def shutdown(code, reason)
        frame(reason, :close, code)
        @frame = @message = nil
        @ready_state = 3
        @stage = 5
        emit(:close, CloseEvent.new(code, reason))
        @extensions.close
      end

      def fail(type, message)
        emit(:error, ProtocolError.new(message))
        shutdown(ERRORS[type], message)
      end

      def parse_opcode(data)
        rsvs = [RSV1, RSV2, RSV3].map { |rsv| (data & rsv) == rsv }

        @frame = Frame.new

        @frame.final  = (data & FIN) == FIN
        @frame.rsv1   = rsvs[0]
        @frame.rsv2   = rsvs[1]
        @frame.rsv3   = rsvs[2]
        @frame.opcode = (data & OPCODE)

        unless @extensions.valid_frame_rsv?(@frame)
          return fail(:protocol_error,
              "One or more reserved bits are on: reserved1 = #{@frame.rsv1 ? 1 : 0}" +
              ", reserved2 = #{@frame.rsv2 ? 1 : 0 }" +
              ", reserved3 = #{@frame.rsv3 ? 1 : 0 }")
        end

        unless OPCODES.values.include?(@frame.opcode)
          return fail(:protocol_error, "Unrecognized frame opcode: #{@frame.opcode}")
        end

        unless MESSAGE_OPCODES.include?(@frame.opcode) or @frame.final
          return fail(:protocol_error, "Received fragmented control frame: opcode = #{@frame.opcode}")
        end

        if @message and OPENING_OPCODES.include?(@frame.opcode)
          return fail(:protocol_error, 'Received new data frame but previous continuous frame is unfinished')
        end

        @stage = 1
      end

      def parse_length(data)
        @frame.masked = (data & MASK) == MASK
        if @require_masking and not @frame.masked
          return fail(:unacceptable, 'Received unmasked frame but masking is required')
        end

        @frame.length = (data & LENGTH)

        if @frame.length >= 0 and @frame.length <= 125
          return unless check_frame_length
          @stage = @frame.masked ? 3 : 4
        else
          @frame.length_bytes = (@frame.length == 126) ? 2 : 8
          @stage = 2
        end
      end

      def parse_extended_length(buffer)
        @frame.length = integer(buffer)

        unless MESSAGE_OPCODES.include?(@frame.opcode) or @frame.length <= 125
          return fail(:protocol_error, "Received control frame having too long payload: #{@frame.length}")
        end

        return unless check_frame_length

        @stage  = @frame.masked ? 3 : 4
      end

      def check_frame_length
        length = @message ? @message.data.size : 0

        if length + @frame.length > @max_length
          fail(:too_large, 'WebSocket frame length too large')
          false
        else
          true
        end
      end

      def emit_frame(buffer)
        frame   = @frame
        payload = frame.payload = Mask.mask(buffer, @frame.masking_key)
        opcode  = frame.opcode

        @frame = nil

        case opcode
          when OPCODES[:continuation] then
            return fail(:protocol_error, 'Received unexpected continuation frame') unless @message
            @message << frame

          when OPCODES[:text], OPCODES[:binary] then
            @message = Message.new
            @message << frame

          when OPCODES[:close] then
            code   = (payload.size >= 2) ? 256 * payload[0] + payload[1] : nil
            reason = (payload.size > 2) ? Driver.encode(payload[2..-1] || [], :utf8) : nil

            unless (payload.size == 0) or
                   (code && code >= MIN_RESERVED_ERROR && code <= MAX_RESERVED_ERROR) or
                   ERROR_CODES.include?(code)
              code = ERRORS[:protocol_error]
            end

            if payload.size > 125 or (payload.size > 2 and reason.nil?)
              code = ERRORS[:protocol_error]
            end

            shutdown(code, reason || '')

          when OPCODES[:ping] then
            frame(payload, :pong)

          when OPCODES[:pong] then
            message = Driver.encode(payload, :utf8)
            callback = @ping_callbacks[message]
            @ping_callbacks.delete(message)
            callback.call if callback
        end

        emit_message if frame.final and MESSAGE_OPCODES.include?(opcode)
      end

      def emit_message
        message  = @extensions.process_incoming_message(@message)
        @message = nil

        payload = message.data
        payload = Driver.encode(payload, :utf8) if message.frames.first.opcode == OPCODES[:text]

        if payload
          emit(:message, MessageEvent.new(payload))
        else
          fail(:encoding_error, 'Could not decode a text frame as UTF-8')
        end
      rescue ::WebSocket::Extensions::ExtensionError => e
        fail(:extension_error, e.message)
      end

      def integer(bytes)
        number = 0
        bytes.each_with_index do |data, i|
          number += data << (8 * (bytes.size - 1 - i))
        end
        number
      end
    end

  end
end
