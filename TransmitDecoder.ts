const InputToArray = (input: string) => {
    let array: string[] = [];
    array.push(input.slice(2, 10));
    for (let i = 10; i < input.length; i += 64) {
        array.push(input.slice(i, i + 64));
    }
    return array;
}

const CreateMstore = (index: number, value: string) => {
    let offset: string  = "0x" + (index * 32).toString(16);
    let word: string = "0x" + value;
    return `mstore(add(mptr, ${offset}), ${word})`
}


const DecodeToYul = (input: string) => {
    let result: string[];
    let array: string[] = InputToArray(input);
    result = array.map((value, index) => {
        return CreateMstore(index, value);
    });
    result.push(`mstore(0x40, add(mptr, 0x${ (array.length * 32).toString(16) }))`);
    return result.join("\n");
}

export default DecodeToYul;