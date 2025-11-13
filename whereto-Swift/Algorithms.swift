import Foundation

func TempoDeExec(funcao: () -> Void) -> Double {
    let tempoInicial = DispatchTime.now()

    funcao()

    let tempoFinal = DispatchTime.now()

    let nanosegundos = tempoFinal.uptimeNanoseconds - tempoInicial.uptimeNanoseconds

    let tempoDecorrido = Double(nanosegundos) / 1_000_000_000.0

    print("Tempo de execução: \(String(format: "%.5f", tempoDecorrido)) segundos")

    return tempoDecorrido
}

//exemplo
let tempo = TempoDeExec {
    if let indice = pesquisaLinear(array: [10, 25, 100, 11000], alvo: 11000) {
        print(indice)
    }
}

//Pesquisa Linear
//T: Equatable = Indica que essa função pode receber qualquer tipo de valor, T sendo um tipo genérico que será trocado pelo real tipo durante a compilação, e Equatable permite que esses
//                valores T possam ser comparados.
//                *Necessário para utilizar a mesma função para diferentes tipos de variaveis.
// -> Int? = Signfica que a função retorna um valor do tipo int, com o ? signficando que esse retorno é opcional.
func pesquisaLinear<T: Equatable>(array: [T], alvo: T) -> Int? {
    for (indice, elemento) in array.enumerated() {
        if elemento == alvo {
            return indice
        }
    }
    return nil
}

//Pesquisa Binária
// T: Comparable = Permite usar todos os tipos de comparações (>=, <=, >, = , <) para as variaveis T
func pesquisaBinaria<T: Comparable>(array: [T], alvo: T) -> Any? {
    var fim = array.count - 1
    var inicio = 0
    var etapas = 0

    while inicio <= fim {
        let meio = inicio + (fim - inicio) / 2
        let valorMeio = array[meio]
        print(valorMeio)
        etapas = etapas + 1

        if valorMeio == alvo {
            print(etapas)
            return meio
        } else if valorMeio > alvo {  //se o valor central for maior que o alvo
            fim = meio - 1
        } else {  //se o valor central for menor que o alvo
            inicio = meio + 1
        }
    }
    print(etapas)
    return nil
}

//Ordenação

/* Exemplo de estrutura para teste
struct Produto {
    let nome: String
    let valor: Int
}

// Array de produtos (seus itens do banco de dados, não ordenados)
let produtos = [
    Produto(nome: "Monitor", valor: 100),
    Produto(nome: "Teclado", valor: 100),
    Produto(nome: "Mouse", valor: 100),
    Produto(nome: "CPU", valor: 1),
    Produto(nome: "Webcam", valor: 10),
]
*/

func merge<T>(_ esquerda: [T], _ direita: [T], by isOrderedBefore: (T, T) -> Bool) -> [T] {
    var indiceEsquerdo = 0
    var indiceDireito = 0
    var arrayOrdenado: [T] = []

    while indiceEsquerdo < esquerda.count && indiceDireito < direita.count {
        if isOrderedBefore(esquerda[indiceEsquerdo], direita[indiceDireito]) {
            arrayOrdenado.append(esquerda[indiceEsquerdo])
            indiceEsquerdo += 1
        } else {
            arrayOrdenado.append(direita[indiceDireito])
            indiceDireito += 1
        }
    }

    arrayOrdenado.append(contentsOf: esquerda[indiceEsquerdo...])
    arrayOrdenado.append(contentsOf: direita[indiceDireito...])

    return arrayOrdenado
}

func mergeSort<T>(_ array: [T], by isOrderedBefore: (T, T) -> Bool) -> [T] {
    guard array.count > 1 else { return array }

    let indiceMeio = array.count / 2

    let arrayEsquerdo = mergeSort(Array(array[0..<indiceMeio]), by: isOrderedBefore)
    let arrayDireito = mergeSort(Array(array[indiceMeio..<array.count]), by: isOrderedBefore)

    return merge(arrayEsquerdo, arrayDireito, by: isOrderedBefore)
}

/*Utilizar tuplas para ordenar com base em 2 parametros ou mais
isOrderedBefore = Critério de ordernação
(<)=ordem crescente / (>)=ordem decrescente
negativar valores numéricos serve para inverter sua ordem na comparação, sem que altere a ordem de comparação dos outros elementos

let ordem_tupla = mergeSort(produtos) { ($0.valor, $0.nome) < ($1.valor, $1.nome) }
ordem_tupla.forEach { print($0.valor, $0.nome) }
*/

struct Produto {
    let nome: String
    let valor: Int
}

let produtos = [
    Produto(nome: "Monitor", valor: 100),
    Produto(nome: "Teclado", valor: 100),
    Produto(nome: "Mouse", valor: 100),
    Produto(nome: "CPU", valor: 1),
    Produto(nome: "Webcam", valor: 10),
]

let ordem_tupla = mergeSort(produtos) { ($0.valor, $0.nome) < ($1.valor, $1.nome) }
ordem_tupla.forEach { print($0.valor, $0.nome) }
