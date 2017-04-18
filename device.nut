
enum SIM800_STATE {
    INITIAL,
    NEGOTIATING,
    RECEIVING
}


class SIM800 {
    _uart = null;
    _state = null;
    _queue = null;
    _receiveMessage = null;
    _shouldLog = null;
    _currentCommand = null;
    _httpResponse = null;
    _isGPRSConnected = null;

    static CID = 1;
    static COMMANDS = {
        HTTPINIT = {
            cmd = "HTTPINIT",
            eos = regexp(@"\s+OK\s+$")
        },
        HTTPTERM = {
            cmd = "HTTPTERM",
            eos = regexp(@"\s+OK\s+$")
        },
        HTTPPARA = {
            cmd = "HTTPPARA",
            eos = regexp(@"\s+OK\s+$")
        },
        HTTPACTION = {
            cmd = "HTTPACTION",
            eos = regexp(@"HTTPACTION: (\d+),(\d+),(\d+)\s+$"),
        },
        HTTPREAD = {
            cmd = "HTTPREAD",
            eos = regexp(@"\s+OK\s+$")
           // eos = regexp(@"HTTPREAD: (\d+)((.|\s)*)OK\s+$")

        },
        SAPBR = {
            cmd = "SAPBR",
            eos = regexp(@"\s+OK\s+$")
        }
    }

    constructor(uart, params){
        _uart = uart;
        _queue = [];
        _receiveMessage = "";
        _httpResponse = {};
        _isGPRSConnected = false;
        local baudRate = ("baudRate" in params) ? params.baudRate : 115200;
        local wordSize = ("wordSize" in params) ? params.wordSize : 8;
        local parity = ("parity" in params) ? params.parity : PARITY_NONE;
        local stopBits = ("stopBits" in params) ? params.stopBits : 1;
        _shouldLog = ("shouldLog" in params) ? params.shouldLog : false;
        _uart.configure(baudRate, wordSize, parity, stopBits, NO_CTSRTS, _readCommand.bindenv(this));
    }

    function sendHttpRequest(url,method,callback = null){
        local methodCode;
        switch(method.tolower()){
            case "get":
                _createHttpGETRequest(url);
                break;
            case "post":
                _createHttpPOSTRequest(url);
                break;
            default :
                throw "it only supports GET and POST";
        }
        if (callback){
            _enqueue(function(){
                callback(_httpResponse);
            });
        }
    }

    function openGPRSConnection(apn){
        _sendCommand(COMMANDS.SAPBR.cmd , "=3," + CID + ",\"CONTYPE\",\"GPRS\"");
        _sendCommand(COMMANDS.SAPBR.cmd , "=3," + CID + ",\"APN\",\"" + apn + "\"");
        _sendCommand(COMMANDS.SAPBR.cmd , "=1," + CID);
    }

    function _createHttpGETRequest(url){
        _sendCommand(COMMANDS.HTTPINIT.cmd);
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"CID\"," + CID);
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"URL\"," + url);
        _sendCommand(COMMANDS.HTTPACTION.cmd , "=0");
        _sendCommand(COMMANDS.HTTPREAD.cmd);
    }


    function _createHttpPOSTRequest(url){
        _sendCommand(COMMANDS.HTTPINIT.cmd);
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"CID\"," + CID);
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"URL\"," + url);
        _sendCommand(COMMANDS.HTTPACTION.cmd , "=1");
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"Content\",")
        _sendCommand(COMMANDS.HTTPREAD.cmd);
    }



    function _sendCommand(command, query = "") {
        _enqueue(function(){
            _writeCommand(command, query);
        });
    }

    function _writeCommand(command, query){
        _currentCommand = command;
        _uart.write("AT+" + command + query + "\n");
        _log("sending command : " + "AT+" + command + query );
    }

    function _enqueue(action){
        action = action.bindenv(this);
        _queue.push(action);
        if (_queue.len() == 1){
            action();
        }
    }

    function _nextInQueue(){
        _queue.remove(0);
        if (_queue.len()){
            imp.wakeup(2,function(){
                _queue[0]();
            }.bindenv(this))
        }
    }

    function _readCommand(){
        local command = _uart.readstring();
        _receiveMessage += command;
        local match = COMMANDS[_currentCommand].eos.capture(_receiveMessage);
        if (match || _receiveMessage.find("\nERROR")){
            _log("receiving command : " + _receiveMessage);
            _processCommand(_currentCommand, match);
            _nextInQueue();
            _receiveMessage = "";
        }
    }

    function _processCommand(currentCommand, match){
        switch(currentCommand){
            case COMMANDS.HTTPACTION.cmd:
                foreach(key, value in match){
                    switch(key){
                        case 2:
                            _httpResponse.status <- _receiveMessage.slice(value.begin, value.end);
                            break;
                        case 3:
                            _httpResponse.size <- _receiveMessage.slice(value.begin, value.end);
                            break;
                    }
                }
                break;
            case COMMANDS.HTTPREAD.cmd:
                local lines = split(_receiveMessage, "\n");
                // remove the first two and last two substrings
                lines.pop();
                lines.pop();
                lines.remove(0);
                lines.remove(0);
                local content = "";
                foreach(line in lines){
                    content += line + "\n"
                }
                _httpResponse.content <- content;
                break;

        }
    }

    function _log(message) {
        if (_shouldLog) {
            server.log(message);
        }
    }
}


local uart = hardware.uart6E;
sim800 <- SIM800(uart,{
    shouldLog = true
});
sim800.openGPRSConnection("internet");


sim800.sendHttpRequest("http://www.google.com","get", function(response){
    foreach(k,v in response){
        server.log("key is "+k);
        server.log("value is " + v);
    }
});
