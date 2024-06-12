package propo

import (
	"bufio"
	"bytes"
	"encoding/binary"
)

func Encode(msg string) ([]byte, error) {

	var leng = int32(len(msg))
	var pkg = new(bytes.Buffer)

	err := binary.Write(pkg, binary.LittleEndian, leng)
	if err != nil {
		return nil, err
	}

	err = binary.Write(pkg, binary.LittleEndian, []byte(msg))
	if err != nil {
		return nil, err
	}
	return pkg.Bytes(), nil
}

func Decode(reader *bufio.Reader) (string, error) {

	lengByte, _ := reader.Peek(4) //读取前4个字节的数据
	lengBuff := bytes.NewBuffer(lengByte)

	var leng int32
	err := binary.Read(lengBuff, binary.LittleEndian, &leng)
	if err != nil {
		return "", err
	}

	if int32(reader.Buffered()) < leng+4 {
		return "", err
	}

	pack := make([]byte, int(4+leng))
	_, err = reader.Read(pack)
	if err != nil {
		return "", err
	}

	return string(pack[4:]), nil
}
