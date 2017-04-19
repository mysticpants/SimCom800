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
    _isHTTPEnabled = null;

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
        },
        CMGF = {
            cmd = "CMGF",
            eos = regexp(@"\s+OK\s+$")
        },
        CMGS = {
            cmd = "CMGS",
            eos = regexp(@"\s+>\s+$")
        },
        CSCS = {
            cmd = "CSCS",
            eos = regexp(@"\s+OK\s+$")
        },
        CMGR = {
            cmd = "CMGR",
            eos = regexp(@"CMGR: (.+)OK\s+$")
        },
        WRITEMESSAGE = {
            cmd = "WRITEMESSAGE",
            eos = regexp(@"OK\s+\+CMTI: .+,(\d+)\s+$")
        }
    }

    constructor(uart, params){
        _uart = uart;
        _queue = [];
        _receiveMessage = "";
        _response = {};
        _isGPRSConnected = false;
        _isHTTPEnabled = false;
        local baudRate = ("baudRate" in params) ? params.baudRate : 115200;
        local wordSize = ("wordSize" in params) ? params.wordSize : 8;
        local parity = ("parity" in params) ? params.parity : PARITY_NONE;
        local stopBits = ("stopBits" in params) ? params.stopBits : 1;
        _shouldLog = ("shouldLog" in params) ? params.shouldLog : false;
        _uart.configure(baudRate, wordSize, parity, stopBits, NO_CTSRTS, _readCommand.bindenv(this));
    }

    function _sendHttpRequest(url,method, headers , data, callback){
        _verifyPreconditions({
            "GPRS connected" : _isGPRSConnected,
            "HTTP enabled" : _isHTTPEnabled
        });
        local methodCode;
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"URL\"," + url);
        if (regexp(@"^https://").capture(url)){
            _sendCommand(COMMANDS.HTTPSSL.cmd, "=1");
        } else {
            _sendCommand(COMMANDS.HTTPSSL.cmd, "=0");
        }
        if (headers){
            local header ="";
            foreach(k,v in headers){
                header += k + ": " + v + "\n";
            }
            _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"USERDATA\",\"" + rstrip(header) + "\"");
        }
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
        _invokeCallback(callback);
        _resetResponse();
    }


    function get(url, headers = null, callback = null){
        _sendHttpRequest(url,"get", headers ,null, callback);
    }

    function post(url, headers ,data,callback = null){
        _sendHttpRequest(url,"post", headers , data, callback);
    }

    function enableHTTP(){
        _sendCommand(COMMANDS.HTTPINIT.cmd);
        _sendCommand(COMMANDS.HTTPPARA.cmd , "=\"CID\"," + CID);
    }

    function disableHTTP(){
        _sendCommand(COMMANDS.HTTPTERM.cmd);
    }

    function openGPRSConnection(apn){
        _sendCommand(COMMANDS.SAPBR.cmd , "=3," + CID + ",\"CONTYPE\",\"GPRS\"");
        _sendCommand(COMMANDS.SAPBR.cmd , "=3," + CID + ",\"APN\",\"" + apn + "\"");
        _sendCommand(COMMANDS.SAPBR.cmd , "=1," + CID);
    }

    function getLocation(callback = null){
        _verifyPreconditions({
            "GPRS connected" : _isGPRSConnected,
        });
        _sendCommand(COMMANDS.CIPGSMLOC.cmd, "=1," + CID);
        _invokeCallback(callback);
        _resetResponse();
    }

    function closeGPRSConnection(){
        _sendCommand(COMMANDS.SAPBR.cmd , "=0," + CID);
    }

    function sendSMS(number, message, callback = null){
        _sendCommand(COMMANDS.CMGF.cmd, "=1");
        _sendCommand(COMMANDS.CSCS.cmd, "=\"GSM\"");
        _sendCommand(COMMANDS.CMGS.cmd, "=\"" + number + "\"");
        _sendData(COMMANDS.WRITEMESSAGE.cmd, message + "\x1a");
        _invokeCallback(callback);
    }

    function readSMS(position, callback = null){
        _sendCommand(COMMANDS.CMGR.cmd, "=" + position);
        _invokeCallback(callback);
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

    function _verifyPreconditions(conditions){
        foreach(key, value in conditions){
            if (!value){
                throw key + " is violated";
            }
        }
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

    function _join(array, connector){
        local result = "";
        foreach(element in array){
            result += element + connector;
        }
        return result;
    }

    function _readCommand(){
        local command = _uart.readstring();
        _receiveMessage += command;
        //server.log(command);
        local match = COMMANDS[_currentCommand].eos.capture(_receiveMessage);
        local hasError = _receiveMessage.find("\nERROR");
        if (match || hasError){
            _log("receiving command : " + _receiveMessage);
            if (hasError) {
                throw "Error sending command : " + _currentCommand;
            }
            if (match){
                _processCommand(_currentCommand, match);
            }
            _nextInQueue();
            _receiveMessage = "";
        }

    }

    function _processCommand(currentCommand, match){
        switch(currentCommand){
            case COMMANDS.SAPBR.cmd:
                _isGPRSConnected = !_isGPRSConnected;
                break;
            case COMMANDS.HTTPINIT.cmd:
            case COMMANDS.HTTPTERM.cmd:
                _isHTTPEnabled = !_isHTTPEnabled;
                break;
            case COMMANDS.HTTPACTION.cmd:
                _response.status <- _receiveMessage.slice(match[2].begin, match[2].end);
                _response.size <- _receiveMessage.slice(match[3].begin, match[3].end);
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
                _response.content <- _join(lines,"\n");
                break;
            case COMMANDS.CIPGSMLOC.cmd:
                _response.locationCode <- _receiveMessage.slice(match[1].begin, match[1].end);
                _response.longitude <- _receiveMessage.slice(match[2].begin, match[2].end);
                _response.latitude <- _receiveMessage.slice(match[3].begin, match[3].end);
                break;
            case COMMANDS.CMGR.cmd:
                local extract = _receiveMessage.slice(match[1].begin, match[1].end);
                local substrings = split(extract,"\n");
                local messageInfo = substrings.remove(0);
                local messageContent = _join(substrings,"\n");
                messageInfo = split(messageInfo,",");
                _response.message <- messageContent;
                _response.sender <- messageInfo[1];
                _response.time <- messageInfo[3] + "," + messageInfo[4];
                break;
            case COMMANDS.WRITEMESSAGE.cmd:
                //server.log();
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

sim800.enableHTTP();


/*
sim800.getLocation(function(response){
    foreach(k,v in response){
        server.log("key is "+k);
        server.log("value is " + v);
    }
});
*/

sim800.get("https://api.staging.conctr.com/admin/users/apps", {
    Authorization = "jwt:eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzYWx0IjowLjMxMTIzNzMzMjExNzA1NjMsInVzZXJJZCI6ImIzZjM0Zjg0ODUyOTQzMTk4MWM4MmVlMGY5MTFkM2UzIiwiaWF0IjoxNDkyNTg2NjkxLCJleHAiOjE0OTI2NzMwOTF9.VbuK4UGjq16Hig2GJlMxxE1SrUgelM-fp8pnVUGamiw"
} , function(response){
    foreach(k,v in response){
        server.log("key is "+k);
        server.log("value is " + v);
    }
});

sim800.post("https://api.staging.conctr.com/admin/apps", {
    Authorization = "jwt:eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzYWx0IjowLjMxMTIzNzMzMjExNzA1NjMsInVzZXJJZCI6ImIzZjM0Zjg0ODUyOTQzMTk4MWM4MmVlMGY5MTFkM2UzIiwiaWF0IjoxNDkyNTg2NjkxLCJleHAiOjE0OTI2NzMwOTF9.VbuK4UGjq16Hig2GJlMxxE1SrUgelM-fp8pnVUGamiw"
} ,{"app_name": "sent from sim800"},function(response){
    foreach(k,v in response){
        server.log(format("%s is %s",k,v));
    }
});




sim800.disableHTTP();


sim800.closeGPRSConnection();




/*
sim800.sendSMS("+61420861828","hello \n it is me");
sim800.readSMS(54,function(response){
    foreach(k,v in response){
        server.log(format("%s is %s",k,v));
    }
});
*/
