#require "JSONEncoder.class.nut:2.0.0"

class SIM800 {
    _uart = null;
    _state = null;
    _queue = null;
    _receiveMessage = null;
    _shouldLog = null;
    _currentCommand = null;
    _response = null;
    _isGPRSConnected = null;

    static CID = 1;
    static MAX_TIMEOUT = 100000;
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
        HTTPSSL = {
            cmd = "HTTPSSL",
            eos = regexp(@"\s+OK\s+$")
        },
        HTTPDATA = {
            cmd = "HTTPDATA",
            eos = regexp(@"\s+DOWNLOAD\s+$")
        },
        HTTPTERM = {
            cmd = "HTTPTERM",
            eos = regexp(@"\s+OK\s+$")
        },
        SAPBR = {
            cmd = "SAPBR",
            eos = regexp(@"\s+OK\s+$")
        },
        CIPGSMLOC = {
            cmd = "CIPGSMLOC",
            eos = regexp(@"CIPGSMLOC: (\d+),(.+),(.+),(.+),(.+)\s+OK\s+$")
        },
        WRITEDATA = {
            cmd = "WRITEDATA",
            eos = regexp(@"\s+OK\s+$")
        }
    }

    constructor(uart, params){
        _uart = uart;
        _queue = [];
        _receiveMessage = "";
        _response = {};
        _isGPRSConnected = false;
        local baudRate = ("baudRate" in params) ? params.baudRate : 115200;
        local wordSize = ("wordSize" in params) ? params.wordSize : 8;
        local parity = ("parity" in params) ? params.parity : PARITY_NONE;
        local stopBits = ("stopBits" in params) ? params.stopBits : 1;
        _shouldLog = ("shouldLog" in params) ? params.shouldLog : false;
        _uart.configure(baudRate, wordSize, parity, stopBits, NO_CTSRTS, _readCommand.bindenv(this));
    }

    function _sendHttpRequest(url,method,data,callback = null){
        local methodCode;
        _sendCommand(COMMANDS.HTTPINIT.cmd);
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"CID\"," + CID);
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"URL\"," + url);
        switch(method.tolower()){
            case "get":
                _sendCommand(COMMANDS.HTTPACTION.cmd , "=0");
                break;
            case "post":
                data = JSONEncoder.encode(data);
                _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"CONTENT\",\"application/json\"");
                _sendCommand(COMMANDS.HTTPDATA.cmd , "=" + data.len() + "," + MAX_TIMEOUT);
                _sendData(COMMANDS.WRITEDATA.cmd,data);
                _sendCommand(COMMANDS.HTTPACTION.cmd , "=1");
                break;
        }
        _sendCommand(COMMANDS.HTTPREAD.cmd);
        _sendCommand(COMMANDS.HTTPTERM.cmd);
        _invokeCallback(callback);
        _resetResponse();
    }

    function get(url,callback = null){
        _sendHttpRequest(url,"get",null, callback);
    }

    function post(url,data,callback = null){
        _sendHttpRequest(url,"post",data, callback);
    }

    function openGPRSConnection(apn){
        _sendCommand(COMMANDS.SAPBR.cmd , "=3," + CID + ",\"CONTYPE\",\"GPRS\"");
        _sendCommand(COMMANDS.SAPBR.cmd , "=3," + CID + ",\"APN\",\"" + apn + "\"");
        _sendCommand(COMMANDS.SAPBR.cmd , "=1," + CID);
    }

    function getLocation(callback = null){
        _sendCommand(COMMANDS.CIPGSMLOC.cmd, "=1," + CID);
        _invokeCallback(callback);
        _resetResponse();
    }

    function closeGPRSConnection(){
        _sendCommand(COMMANDS.SAPBR.cmd , "=0," + CID);
    }


    function _sendCommand(command, query = "") {
        _enqueue(function(){
            _writeCommand(command, query);
        });
    }

    function _invokeCallback(callback){
        if (callback){
            _enqueue(function(){
                callback(_response);
                _nextInQueue();
            });
        }
    }

    function _resetResponse(){
        _enqueue(function(){
            _log("reseting _response");
            _response = {};
            _nextInQueue();
        });
    }

    function _sendData(command, data){
        _enqueue(function(){
            _writeData(command, data);
        });
    }

    function _writeData(command, data){
        _currentCommand = command;
        _uart.write(data);
        _log("write data : " + data);
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
            if (match){
                _processCommand(_currentCommand, match);
            }
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
                            _response.status <- _receiveMessage.slice(value.begin, value.end);
                            break;
                        case 3:
                            _response.size <- _receiveMessage.slice(value.begin, value.end);
                            break;
                    }
                }
                break;
            case COMMANDS.HTTPREAD.cmd:
                local lines = split(_receiveMessage, "\n");
                // remove the first  and last substrings
                lines.pop();
                lines.remove(0);
                if (lines.len() >= 4){
                    lines.pop();
                    lines.remove(0);
                }
                local content = "";
                foreach(line in lines){
                    content += line + "\n"
                }
                _response.content <- content;
                break;
            case COMMANDS.CIPGSMLOC.cmd:
                foreach(key, value in match){
                    switch(key){
                        case 1:
                            _response.locationCode <- _receiveMessage.slice(value.begin, value.end);
                            break;
                        case 2:
                            _response.longitude <- _receiveMessage.slice(value.begin, value.end);
                            break;
                        case 3:
                            _response.latitude <- _receiveMessage.slice(value.begin, value.end);
                            break;
                    }
                }
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


/*
sim800.get("http://www.google.com", function(response){
    foreach(k,v in response){
        server.log("key is "+k);
        server.log("value is " + v);
    }
});
*/




/*
sim800.getLocation(function(response){
    foreach(k,v in response){
        server.log("key is "+k);
        server.log("value is " + v);
    }
});
*/


sim800.post("http://httpbin.org/post",{"one":1,"two":2},function(response){
    foreach(k,v in response){
        server.log(format("%s is %s",k,v));
    }
});

sim800.closeGPRSConnection();
