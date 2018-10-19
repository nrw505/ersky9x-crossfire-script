array byte deviceIds[6]
array byte deviceNames[100]
array byte deviceParameterCounts[6]
array byte deviceParameterVersionNumbers[6]
array byte parameterNames[252]
array byte parameterFetched[16]
array parameterNextFetch[16]
array byte parameterType[16]
array byte parameterHidden[16]
array byte parameterParent[16]
array byte parameterCommandStatus[16]
array byte parameterCommandTimeout[16]
array byte parameterCommandInfo[252]
array byte parameterStringCurrentValues[252]
array parameterValue[16]
array parameterMinValue[16]
array parameterMaxValue[16]
array parameterDefaultValue[16]

array byte parameterTempString[252]
array byte parameterTempStringIndices[16]

array deviceTimeouts[6]
array byte receiveBuffer[64]
array byte transmitBuffer[64]

array menuItems[16]

if init = 0
    init = 1
    deviceIndex = 0
    deviceCount = 0

    responseTimeout = 0
    waitForResponse = 0

    menuItemCount = 0
    menuItemIndex = 0

    parameterIndex = 0
    parameterEdit = 0

    currentFolder = 0

    pktsRead = 0
    pktsSent = 0
    pktsGood = 0
    pktsWrongDev = 0
    pktsWrongParam = 0

    STATE_DEVICE_LIST = 0
    STATE_DEVICE_SETUP = 1
    STATE_RUN_COMMAND = 2

    state = STATE_DEVICE_LIST

    DEVICE_ID_BROADCAST = 0
    DEVICE_ID_RADIO_TX = 0xEA

    FRAME_POLL_DEVICES = 0x28
    FRAME_DEVICE_INFO = 0x29
    FRAME_PARAMETER_INFO = 0x2B
    FRAME_POLL_PARAMETERS = 0x2C
    FRAME_SET_PARAMETER = 0x2D

    TYPE_SELECT = 9
    TYPE_FOLDER = 11
    TYPE_INFO = 12
    TYPE_COMMAND = 13

    COMMAND_STATUS_READY = 0
    COMMAND_STATUS_START = 1
    COMMAND_STATUS_PROGRESS = 2
    COMMAND_STATUS_PLS_CONFIRM = 3
    COMMAND_STATUS_CONFIRM = 4
    COMMAND_STATUS_CANCEL = 5
    COMMAND_STATUS_POLL = 6

    DEVICE_TIMEOUT = 300
    PARAMETER_TIMEOUT = 20
    PARAMETER_REFETCH_TIMEOUT = 300
    SET_PARAMETER_TIMEOUT = 100
    SEND_FAIL_TIMEOUT = 10

    rem -- including terminating zero
    rem -- @todo should be 45 according to spec, change later
    kMaxDeviceNameLength = 16
    rem -- dictated by the number of device names we could fit, will be raised later
    kMaxDeviceCount = 6
    kMaxParameterNameLength = 14
    kMaxParameterCount = 16
    kMaxMenuItems = 16

    rem -- purge the crossfire packet fifo
    result = crossfirereceive(count, command, receiveBuffer)
    while result = 1
        result = crossfirereceive(count, command, receiveBuffer)
    end

    gosub requestDeviceData
end

goto main

sendPacket:
    result = crossfiresend(sendCommand, sendLength, transmitBuffer)
    if result = 1
        pktsSent += 1
        responseTimeout = time + sendTimeout
    else
        responseTimeout = time + SEND_FAIL_TIMEOUT
    end
    return

gotResponsePacket:
    responseTimeout = 0
    waitForResponse = 0
    return

requestDeviceData:
    transmitBuffer[0] = DEVICE_ID_BROADCAST
    transmitBuffer[1] = DEVICE_ID_RADIO_TX
    sendCommand = FRAME_POLL_DEVICES
    sendLength = 2
    waitForResponse = 0
    responseTimeout = 0
    gosub sendPacket
    return

requestParameterData:
    transmitBuffer[0] = deviceIds[deviceIndex]
    transmitBuffer[1] = DEVICE_ID_RADIO_TX
    transmitBuffer[2] = requestParameter
    transmitBuffer[3] = requestChunk
    sendCommand = FRAME_POLL_PARAMETERS
    sendLength = 4
    sendTimeout = PARAMETER_TIMEOUT
    waitForResponse = 1
    gosub sendPacket
    return

sendNextPacket:
    rem -- if we're waiting for a response, retransmit the previous
    rem -- packet after a timeout
    if waitForResponse = 1 & responseTimeout > 0
        if time > responseTimeout
            gosub sendPacket
        end
        return
    end

    rem -- should we refresh any parameters?
    rem -- don't bother if we're in the device list page
    i = 0
    while i < kMaxParameterCount & i < deviceParameterCounts[deviceIndex] & state != STATE_DEVICE_LIST
        rem -- if (parameterFetched[i] = 0) | (time > parameterNextFetch[i])
        if (parameterFetched[i] = 0) | (time > parameterNextFetch[i])
            requestParameter = i + 1
            requestChunk = 0
            gosub requestParameterData
            return
        end
        i += 1
    end

    rem -- should we refresh devices?
    rem -- nah.

    return

checkForPackets:
    command = 0
    count = 0

    result = crossfirereceive(count, command, receiveBuffer)
    while result = 1
        pktsRead += 1
        if command = FRAME_DEVICE_INFO
            pktsGood += 1
            gosub parseDeviceInfo
        end
        if command = FRAME_PARAMETER_INFO
            gosub parseParameterInfo
        end
        result = crossfirereceive(count, command, receiveBuffer)
    end

    return

parseDeviceInfo:
    rem -- payload format:
    rem --  uint8_t Destination node address
    rem --  uint8_t Device node address
    rem --  char[] Device name ( Null-terminated string )
    rem --  uint32_t Serial number
    rem --  uint32_t Hardware ID
    rem --  uint32_t Firmware ID
    rem --  uint8_t Parameters count
    rem --  uint8_t Parameter version number

    id = receiveBuffer[1]
    index = 0

    while (index < deviceCount) & (id != deviceIds[index])
        index += 1
    end

    rem -- add new device
    if index = deviceCount
        if deviceCount < kMaxDeviceCount
            rem -- device fits
            deviceCount += 1
        else
            rem -- have to evict one of the devices to fit
            index -= 1
        end
    end

    rem -- fill device entry
    deviceIds[index] = id

    nameOffset = kMaxDeviceNameLength * index
    i = 0

    rem -- copy device name string
    rem -- @todo remove whitespace or trim the string to allow more devices in one array
    i = 0
    while (receiveBuffer[i + 2] != 0) & (i < kMaxDeviceNameLength - 1)
        deviceNames[nameOffset + i] = receiveBuffer[i + 2]
        i += 1
    end

    rem -- add terminating zero
    deviceNames[nameOffset + i] = 0
    deviceParameterCounts[index] = receiveBuffer[i + 15]
    deviceParameterVersionNumbers[index] = receiveBuffer[i + 16]

    deviceTimeouts[index] = gettime() + DEVICE_TIMEOUT

    return

parseParameterInfo:
    rem # payload format:
    rem --  uint8_t Destination node address
    rem --  uint8_t Device node address
    rem --  uint8_t Parameter Number
    rem --  uint8_t Chunks remaining
    rem --  uint8_t Parent Parameter Number
    rem --  uint8_t type and hidden bit
    rem --  char[] Parameter Name (null terminated)
    rem --  ... depending on type

    index = receiveBuffer[2] - 1
    chunksRemaining = receiveBuffer[3]

    if receiveBuffer[1] != deviceIds[deviceIndex]
        pktsWrongDev += 1
        return
    end

    rem -- if it's parameterId 0 it's the root menu, and we don't care
    rem -- just ask again for the one we want
    if receiveBuffer[2] = 0
        pktsWrongParam += 1
        return
    end

    rem -- requestParameter = receiveBuffer[2] + 1
    rem -- if requestParameter > deviceParameterCounts[deviceIndex]
    rem --     requestParameter = 1
    rem --     requestChunk = 0
    rem -- end
    rem -- gosub requestParameterData

    pktsGood += 1

    rem -- it seems to be very important that we request a bunch of
    rem -- parameters in order, otherwise the crossfire module shits itself
    rem -- and starts sending parameter 0 'root' over and over.
    rem -- so we'll send the next packet now rather than waiting until after
    rem -- the screen update

    parameterFetched[index] = 1
    parameterNextFetch[index] = time + PARAMETER_REFETCH_TIMEOUT
    gosub gotResponsePacket
    gosub sendNextPacket

    parameterParent[index] = receiveBuffer[4]
    parameterType[index] = receiveBuffer[5]
    parameterHidden[index] = 0
    if parameterType[index] > 127
        parameterHidden[index] = 1
        parameterType[index] -= 128
    end

    i = 0
    nameOffset = kMaxParameterNameLength * index
    while (receiveBuffer[i + 6] != 0) & (i < kMaxParameterNameLength - 1)
        parameterNames[nameOffset + i] = receiveBuffer[i + 6]
        i += 1
    end
    parameterNames[nameOffset + i] = 0

    if parameterType[index] = TYPE_SELECT
        j = 0
        k = 0
        parameterTempStringIndices[k] = j
        while receiveBuffer[i + j + 7] != 0
            parameterTempString[j] = receiveBuffer[i + j + 7]
            rem -- turn ; into null terminators
            if parameterTempString[j] = 59
                k += 1
                parameterTempStringIndices[k] = j + 1
            end
            j += 1
        end
        parameterTempString[j] = 0

        parameterValue[index] = receiveBuffer[i + j + 8]
        parameterMinValue[index] = receiveBuffer[i + j + 9]
        parameterMaxValue[index] = receiveBuffer[i + j + 10]
        parameterDefaultValue[index] = receiveBuffer[i + j + 11]

        i = 0
        stringValueOffset = kMaxParameterNameLength * index
        tstart = parameterTempStringIndices[parameterValue[index]]
        while parameterTempString[tstart + i] != 0 & parameterTempString[tstart + i] != 59
            parameterStringCurrentValues[stringValueOffset + i] = parameterTempString[tstart + i]
            i += 1
        end
    end

    if parameterType[index] = TYPE_INFO
        j = 0
        stringValueOffset = kMaxParameterNameLength * index
        while (receiveBuffer[i + j + 7] != 0) & (j < kMaxParameterNameLength - 1)
            parameterStringCurrentValues[stringValueOffset + j] = receiveBuffer[i + j + 7]
            j += 1
        end
        parameterStringCurrentValues[stringValueOffset + j] = 0
    end

    if parameterType[index] = TYPE_COMMAND
        parameterCommandStatus[index] = receiveBuffer[i + 7]
        parameterCommandTimeout[index] = receiveBuffer[i + 8]
        j = 0
        infoOffset = kMaxParameterNameLength * index
        while (receiveBuffer[i + j + 9] != 0 & (j < kMaxParameterNameLength - 1))
            parameterCommandInfo[infoOffset + j] = receiveBuffer[i + j + 9]
            j += 1
        end
        parameterCommandInfo[infoOffset + j] = 0
    end

    gosub calculateMenuItems
    return

incrementParameter:
    if parameterType[parameterIndex] = TYPE_SELECT
        newValue = parameterValue[parameterIndex] + 1
        if newValue > parameterMaxValue[parameterIndex]
            newValue = parameterMinValue[parameterIndex]
        end
        transmitBuffer[0] = deviceIds[deviceIndex]
        transmitBuffer[1] = DEVICE_ID_RADIO_TX
        transmitBuffer[2] = parameterIndex + 1
        transmitBuffer[3] = newValue
        sendCommand = FRAME_SET_PARAMETER
        sendLength = 4
        sendTimeout = SET_PARAMETER_TIMEOUT
        gosub sendPacket
    end
    return

decrementParameter:
    if parameterType[parameterIndex] = TYPE_SELECT
        newValue = parameterValue[parameterIndex]
        if newValue = parameterMinValue[parameterIndex]
            newValue = parameterMaxValue[parameterIndex]
        else
            newValue = newValue - 1
        end
        transmitBuffer[0] = deviceIds[deviceIndex]
        transmitBuffer[1] = DEVICE_ID_RADIO_TX
        transmitBuffer[2] = parameterIndex + 1
        transmitBuffer[3] = newValue
        sendCommand = FRAME_SET_PARAMETER
        sendLength = 4
        sendTimeout = SET_PARAMETER_TIMEOUT
        gosub sendPacket
    end
    return

startReadingParameters:
    i = 0
    while i < kMaxParameterCount
        parameterFetched[i] = 0
        i += 1
    end
    return

startDeviceSetup:
    state = STATE_DEVICE_SETUP
    parameterIndex = 0
    currentFolder = 0
    gosub startReadingParameters
    return

previousDevice:
    if deviceCount > 0 then deviceIndex = (deviceIndex - 1 + deviceCount) % deviceCount
    return

nextDevice:
    if deviceCount > 0 then deviceIndex = (deviceIndex + 1) % deviceCount
    return

deviceListPage:
    if Event = EVT_EXIT_BREAK
        goto exit
    elseif (Event = EVT_DOWN_FIRST) | (Event = EVT_DOWN_REPT)
        gosub nextDevice
    elseif (Event = EVT_UP_FIRST) | (Event = EVT_UP_REPT)
        gosub previousDevice
    elseif Event = EVT_MENU_BREAK
        rem # go into device setup for selected device
        gosub startDeviceSetup
    end

    drawtext(0, 0, "CROSSFIRE SETUP", INVERS)

    if deviceCount > 0
        i = 0

        while i < deviceCount
            attr = 0
            if i = deviceIndex then attr = INVERS

            nameOffset = kMaxDeviceNameLength * i

            drawtext(0, i * 8 + 9, deviceNames[nameOffset], attr)

            i += 1
        end
    else
        drawtext(0, 28, "Waiting for devices..")
    end

    return

previousParameter:
    if menuItemCount > 0 then menuItemIndex = (menuItemIndex - 1 + menuItemCount) % menuItemCount
    parameterIndex = menuItems[menuItemIndex]
    rem -- paramCount = deviceParameterCounts[deviceIndex]
    rem -- if paramCount > 0 then parameterIndex = (parameterIndex - 1 + paramCount) % paramCount
    return

nextParameter:
    if menuItemCount > 0 then menuItemIndex = (menuItemIndex + 1) % menuItemCount
    parameterIndex = menuItems[menuItemIndex]
    rem -- paramCount = deviceParameterCounts[deviceIndex]
    rem -- if paramCount > 0 then parameterIndex = (parameterIndex + 1) % paramCount
    return

calculateMenuItems:
    i = 0
    m = 0
    while i < deviceParameterCounts[deviceIndex]
        if parameterFetched[i] = 1 & parameterParent[i] = currentFolder & parameterHidden[i] = 0
            menuItems[m] = i
            m += 1
        end
        i += 1
    end
    menuItemCount = m
    while m < kMaxMenuItems
        menuItems[m] = -1
        m += 1
    end
    return

deviceSetupPage:
    if Event = EVT_EXIT_BREAK
        if currentFolder = 0
            state = STATE_DEVICE_LIST
        else
            oldFolder = currentFolder
            currentFolder = parameterParent[currentFolder - 1]
            gosub calculateMenuItems
            m = 0
            while m < kMaxMenuItems
                if menuItems[m] = (oldFolder - 1) then menuItemIndex = m
                m += 1
            end
        end
    elseif (Event = EVT_DOWN_FIRST) | (Event = EVT_DOWN_REPT)
        gosub nextParameter
    elseif (Event = EVT_UP_FIRST) | (Event = EVT_UP_REPT)
        gosub previousParameter
    elseif (Event = EVT_LEFT_FIRST) | (Event = EVT_LEFT_REPT)
        gosub decrementParameter
    elseif (Event = EVT_RIGHT_FIRST) | (Event = EVT_RIGHT_REPT)
        gosub incrementParameter
    elseif (Event = EVT_MENU_BREAK)
        rem # go into edit mode for parameter
        if parameterType[parameterIndex] = TYPE_FOLDER
            currentFolder = parameterIndex + 1
            gosub calculateMenuItems
            menuItemIndex = 0
        elseif parameterType[parameterIndex] = TYPE_COMMAND
            gosub startRunCommand
        elseif parameterType[parameterType] = TYPE_SELECT
            gosub incrementParameter
        else
            parameterEdit = 1
        end
    end

    nameOffset = kMaxDeviceNameLength * deviceIndex
    drawtext(0, 0, deviceNames[nameOffset], INVERS)

    rem -- debug1 = pktsSent
    rem -- debug2 = pktsRead
    rem -- debug3 = pktsGood
    rem -- debug4 = pktsWrongDev
    rem -- debug5 = pktsWrongParam

    debug1 = pktsSent
    debug2 = pktsRead
    debug3 = pktsGood

    if menuItemCount = 0
        drawtext(0, 28, "Waiting for params..")
        return
    end

    row = 0
    while row < menuItemCount & row < 7 & menuItems[row] != -1
        attr = 0
        y = row * 8 + 9
        if row = menuItemIndex then attr = INVERS
        param = menuItems[row]
        nameOffset = kMaxParameterNameLength * param

        if parameterType[param] = TYPE_FOLDER
            drawtext(0, y, parameterNames[nameOffset], 0)
            drawtext(116, y, "->", attr)
        elseif parameterType[param] = TYPE_SELECT
            drawtext(0, y, parameterNames[nameOffset], attr)
            drawtext(80, y, parameterStringCurrentValues[nameOffset], attr)
        elseif parameterType[param] = TYPE_INFO
            drawtext(0, y, parameterNames[nameOffset], attr)
            rem -- position chosen purely to make the XF Micro TX
            rem -- serial number not overflow to the next line
            drawtext(68, y, parameterStringCurrentValues[nameOffset])
        elseif parameterType[param] = TYPE_COMMAND
            drawtext(0, y, parameterNames[nameOffset], attr)
            if attr = INVERS
                drawtext(116, y, "Go", attr)
            end
        else
            drawtext(0, y, parameterNames[nameOffset])
            drawnumber(110, y, parameterType[param], attr, 3)
        end
        row += 1
     end

    drawnumber(127, 0, debug3, 0, 4)
    drawnumber(107, 0, debug2, 0, 4)
    drawnumber(87, 0, debug1, 0, 4)
    rem -- gosub dumpReceiveBuffer
    rem -- gosub dumpParamFetched
    rem -- gosub dumpTransmitBuffer

    return

dumpReceiveBuffer:
    row = 0;
    while row < 7
        col = 0;
        while col < 6
            x = 20 * (col+1)
            y = (row * 8) + 9
            i = (row * 6) + col
            if i < debug2 then drawnumber(x, y, receiveBuffer[i], 0, 3)
            col += 1
        end
        row += 1
    end
    return

dumpTransmitBuffer:
    row = 0;
    while row < 6
        col = 0;
        while col < 6
            x = 20 * (col+1)
            y = (row * 8) + 17
            i = (row * 6) + col
            drawnumber(x, y, transmitBuffer[i], 0, 3)
            col += 1
        end
        row += 1
    end
    return

dumpParamFetched:
    row = 0;
    while row < 4
        col = 0;
        while col < 4
            x = 20 * (col+1)
            y = (row * 8) + 17
            i = (row * 4) + col
            drawnumber(x, y, parameterNextFetch[i], 0, 4)
            col += 1
        end
        row += 1
    end
    return

startRunCommand:
    state = STATE_RUN_COMMAND
    transmitBuffer[0] = deviceIds[deviceIndex]
    transmitBuffer[1] = DEVICE_ID_RADIO_TX
    transmitBuffer[2] = parameterIndex + 1
    transmitBuffer[3] = COMMAND_STATUS_START
    sendCommand = FRAME_SET_PARAMETER
    sendLength = 4
    sendTimeout = SET_PARAMETER_TIMEOUT
    waitForResponse = 1
    gosub sendPacket
    return

cancelRunCommand:
    transmitBuffer[0] = deviceIds[deviceIndex]
    transmitBuffer[1] = DEVICE_ID_RADIO_TX
    transmitBuffer[2] = parameterIndex + 1
    transmitBuffer[3] = COMMAND_STATUS_CANCEL
    sendCommand = FRAME_SET_PARAMETER
    sendLength = 4
    sendTimeout = SET_PARAMETER_TIMEOUT
    waitForResponse = 1
    gosub sendPacket
    return

confirmRunCommand:
    transmitBuffer[0] = deviceIds[deviceIndex]
    transmitBuffer[1] = DEVICE_ID_RADIO_TX
    transmitBuffer[2] = parameterIndex + 1
    transmitBuffer[3] = COMMAND_STATUS_CANCEL
    sendCommand = FRAME_SET_PARAMETER
    sendLength = 4
    sendTimeout = SET_PARAMETER_TIMEOUT
    waitForResponse = 1
    gosub sendPacket
    return

runCommandPage:
    status = parameterCommandStatus[parameterIndex]

    if Event = EVT_EXIT_BREAK
        gosub cancelRunCommand
    elseif Event = EVT_MENU_BREAK & status = COMMAND_STATUS_PLS_CONFIRM
        gosub confirmRunCommand
    end

    nameOffset = kMaxDeviceNameLength * deviceIndex
    drawtext(0, 0, deviceNames[nameOffset], INVERS)

    drawtext(20, 17, parameterNames[kMaxParameterNameLength * parameterIndex])
    if status = COMMAND_STATUS_START
        rem -- dont _think_ this will ever happen, but just in case..
        drawtext(20, 25, "Starting...")
    elseif status = COMMAND_STATUS_PROGRESS
        drawtext(20, 25, "In progress...")
    elseif status = COMMAND_STATUS_PLS_CONFIRM
        drawtext(20, 25, "Please confirm")
        drawtext(10, 41, "[MENU]      [EXIT]")
        drawtext(10, 49, "  OK        CANCEL")
    elseif status = COMMAND_STATUS_READY
        drawtext(20, 25, "Complete!")
        state = STATE_DEVICE_SETUP
    end

    return

main:
    time = gettime()
    gosub checkForPackets

    drawclear()
    if state = STATE_DEVICE_LIST
        gosub deviceListPage
    elseif state = STATE_DEVICE_SETUP
        gosub deviceSetupPage
    elseif state = STATE_RUN_COMMAND
        gosub runCommandPage
    end

    gosub sendNextPacket
    stop

exit:
    finish
